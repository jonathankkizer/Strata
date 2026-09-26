import Foundation

enum AzureCLIError: Error, Sendable, Equatable {
    case binaryNotFound
    case launchFailed(message: String)
    case commandFailed(status: Int32, message: String)
    case malformedResponse
    case timedOut(seconds: Int)

    init(_ failure: CLIProcess.Failure) {
        switch failure {
        case .launchFailed(let message): self = .launchFailed(message: message)
        case .exited(let status, let message): self = .commandFailed(status: status, message: message)
        case .timedOut(let seconds): self = .timedOut(seconds: seconds)
        }
    }
}

extension AzureCLIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Strata couldn\u{2019}t find the Azure CLI."
        case .launchFailed(let message):
            return "The Azure CLI couldn\u{2019}t be started: \(message)"
        case .commandFailed(_, let message):
            // `az` explains itself well ("Please run 'az login' to setup account."),
            // so its own words are the most useful thing to show.
            return message
        case .malformedResponse:
            return "The Azure CLI returned a token Strata couldn\u{2019}t read."
        case .timedOut(let seconds):
            return "The Azure CLI didn\u{2019}t answer within \(seconds) seconds."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .binaryNotFound:
            return "Install it with \u{201C}brew install azure-cli\u{201D} and sign in with \u{201C}az login\u{201D}. If it\u{2019}s installed somewhere unusual, set its location in Settings \u{25B8} Accounts."
        case .commandFailed:
            return "Run \u{201C}az login\u{201D} in Terminal, then try again."
        case .malformedResponse:
            return "Updating the Azure CLI (\u{201C}az upgrade\u{201D}) may help."
        case .timedOut, .launchFailed:
            return "Check that \u{201C}az account get-access-token\u{201D} works in Terminal."
        }
    }
}

/// Mints Azure data-plane tokens by shelling out to
/// `az account get-access-token --resource https://storage.azure.com/`, the same
/// mechanism the official AzureCliCredential uses internally. This is the first
/// step for Azure support: everything else (list, upload, event prediction against
/// real subscriptions) needs a token first.
///
/// `az` is a Python script with a ~1–2s cold start, so tokens are cached and
/// refreshed shortly before expiry — never on the hot path of every request — and
/// concurrent callers share one refresh rather than each starting their own `az`.
/// Finding and running the binary is `CLIProcess`'s job.
actor AzureCLITokenProvider: AzureTokenSource {

    struct Configuration: Sendable {
        /// Where `az` is, for this provider only. Nil falls back to the Settings ▸
        /// Accounts choice, then to searching the usual install locations.
        var explicitBinaryPath: String?
        /// Optional `--subscription` / `--tenant` scoping. The token is
        /// tenant-scoped; the target storage account's tenant must match.
        var subscription: String?
        var tenant: String?
        /// The token audience. Defaults to the data-plane storage resource; the
        /// account picker mints a management-plane token by passing
        /// `AzureAuth.managementResource` instead.
        var resource: String = AzureAuth.storageResource
        /// Refresh this long before expiry so callers never hand out a token that
        /// dies mid-request.
        var refreshMargin: TimeInterval = 300

        init(explicitBinaryPath: String? = nil, subscription: String? = nil, tenant: String? = nil, resource: String = AzureAuth.storageResource, refreshMargin: TimeInterval = 300) {
            self.explicitBinaryPath = explicitBinaryPath
            self.subscription = subscription
            self.tenant = tenant
            self.resource = resource
            self.refreshMargin = refreshMargin
        }
    }

    private let configuration: Configuration
    private var cached: AzureAccessToken?
    /// The refresh in progress, if any. Without this, every request that arrives
    /// while the cache is stale starts its own `az` — eight at once during a delete.
    private var refreshing: Task<AzureAccessToken, any Error>?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Returns a valid data-plane token, minting a fresh one only when the cache is
    /// empty or within `refreshMargin` of expiry.
    func token(asOf now: Date = Date()) async throws -> AzureAccessToken {
        if let cached, cached.expiresOn.timeIntervalSince(now) > configuration.refreshMargin {
            return cached
        }
        if let refreshing {
            return try await refreshing.value
        }
        let task = Task { try await mint() }
        refreshing = task
        defer { refreshing = nil }
        let fresh = try await task.value
        cached = fresh
        return fresh
    }

    /// Drops the cached token (e.g. after a 401), forcing a fresh mint next call.
    func invalidate() async {
        cached = nil
    }

    // MARK: - Minting

    private func mint() async throws -> AzureAccessToken {
        var arguments = [
            "account", "get-access-token",
            "--resource", configuration.resource,
            "--output", "json",
        ]
        if let subscription = configuration.subscription {
            arguments += ["--subscription", subscription]
        }
        if let tenant = configuration.tenant {
            arguments += ["--tenant", tenant]
        }

        let explicitPath = configuration.explicitBinaryPath ?? StrataDefaults.azureCLIPath
        guard let binary = await CLIProcess.locate("az", explicitPath: explicitPath) else {
            throw AzureCLIError.binaryNotFound
        }
        let output: Data
        do {
            output = try await CLIProcess.run(binary: binary, arguments: arguments)
        } catch let failure as CLIProcess.Failure {
            throw AzureCLIError(failure)
        }
        do {
            return try JSONDecoder().decode(TokenPayload.self, from: output).makeToken()
        } catch is DecodingError {
            throw AzureCLIError.malformedResponse
        }
    }
}

/// Decodes `az account get-access-token --output json`. Prefers the `expires_on`
/// epoch (unambiguous) and falls back to the `expiresOn` local-time string emitted
/// by older CLI versions.
private struct TokenPayload: Decodable {
    let accessToken: String
    let expiresOnString: String?
    let expiresOnEpoch: Int?
    let tenant: String?
    let subscription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken
        case expiresOnString = "expiresOn"
        case expiresOnEpoch = "expires_on"
        case tenant
        case subscription
    }

    func makeToken() throws -> AzureAccessToken {
        let expiry: Date
        if let expiresOnEpoch {
            expiry = Date(timeIntervalSince1970: TimeInterval(expiresOnEpoch))
        } else if let expiresOnString, let parsed = TokenPayload.parseLocal(expiresOnString) {
            expiry = parsed
        } else {
            throw AzureCLIError.malformedResponse
        }
        return AzureAccessToken(accessToken: accessToken, expiresOn: expiry, tenant: tenant, subscription: subscription)
    }

    /// `expiresOn` is emitted in the host's local time with no zone marker.
    private static func parseLocal(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
        if let date = formatter.date(from: value) { return date }
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }
}
