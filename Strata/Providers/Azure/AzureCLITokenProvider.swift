import Foundation

enum AzureCLIError: Error, Sendable {
    case binaryNotFound
    case launchFailed(message: String)
    case commandFailed(status: Int32, message: String)
    case malformedResponse
}

/// Mints Azure data-plane tokens by shelling out to
/// `az account get-access-token --resource https://storage.azure.com/`, the same
/// mechanism the official AzureCliCredential uses internally. This is the first
/// step for Azure support: everything else (list, upload, event prediction against
/// real subscriptions) needs a token first.
///
/// Two macOS realities are handled here:
/// - GUI apps launched from Finder do not inherit the shell PATH, so the `az`
///   binary is resolved explicitly (with a Preferences override on top).
/// - `az` is a Python script with a ~1–2s cold start, so tokens are cached and
///   refreshed shortly before expiry — never on the hot path of every request.
actor AzureCLITokenProvider: AzureTokenSource {

    struct Configuration: Sendable {
        /// Preferences "Path to Azure CLI" override; tried before the search paths.
        var explicitBinaryPath: String?
        /// Optional `--subscription` / `--tenant` scoping. The token is
        /// tenant-scoped; the target storage account's tenant must match.
        var subscription: String?
        var tenant: String?
        /// Refresh this long before expiry so callers never hand out a token that
        /// dies mid-request.
        var refreshMargin: TimeInterval = 300

        init(explicitBinaryPath: String? = nil, subscription: String? = nil, tenant: String? = nil, refreshMargin: TimeInterval = 300) {
            self.explicitBinaryPath = explicitBinaryPath
            self.subscription = subscription
            self.tenant = tenant
            self.refreshMargin = refreshMargin
        }
    }

    private let configuration: Configuration
    private var cached: AzureAccessToken?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Returns a valid data-plane token, minting a fresh one only when the cache is
    /// empty or within `refreshMargin` of expiry.
    func token(asOf now: Date = Date()) async throws -> AzureAccessToken {
        if let cached, cached.expiresOn.timeIntervalSince(now) > configuration.refreshMargin {
            return cached
        }
        let fresh = try await mint()
        cached = fresh
        return fresh
    }

    /// Drops the cached token (e.g. after a 401), forcing a fresh mint next call.
    func invalidate() {
        cached = nil
    }

    // MARK: - Minting

    private func resolveBinary() throws -> String {
        let fileManager = FileManager.default
        if let explicit = configuration.explicitBinaryPath, fileManager.isExecutableFile(atPath: explicit) {
            return explicit
        }
        for candidate in AzureAuth.azureCLISearchPaths where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw AzureCLIError.binaryNotFound
    }

    private func mint() async throws -> AzureAccessToken {
        var arguments = [
            "account", "get-access-token",
            "--resource", AzureAuth.storageResource,
            "--output", "json",
        ]
        if let subscription = configuration.subscription {
            arguments += ["--subscription", subscription]
        }
        if let tenant = configuration.tenant {
            arguments += ["--tenant", tenant]
        }

        let binary = try resolveBinary()
        let output = try await Self.run(binary: binary, arguments: arguments)
        do {
            return try JSONDecoder().decode(TokenPayload.self, from: output).makeToken()
        } catch is DecodingError {
            throw AzureCLIError.malformedResponse
        }
    }

    /// Runs the CLI and returns stdout. `az`'s token JSON is a few KB — well under
    /// the pipe buffer — so reading in the termination handler cannot deadlock.
    private nonisolated static func run(binary: String, arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { process in
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: outData)
                } else {
                    let message = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(process.terminationStatus)"
                    continuation.resume(throwing: AzureCLIError.commandFailed(status: process.terminationStatus, message: message))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: AzureCLIError.launchFailed(message: error.localizedDescription))
            }
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
