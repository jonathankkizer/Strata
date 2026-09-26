import Foundation

enum AWSCLIError: Error, Sendable, Equatable {
    case binaryNotFound
    case launchFailed(message: String)
    case commandFailed(status: Int32, message: String)
    case malformedResponse
    /// The CLI resolved the profile but the credentials it returned have already
    /// expired — an SSO session that needs `aws sso login` again.
    case credentialsExpired(profile: String)
    case timedOut(seconds: Int)

    init(_ failure: CLIProcess.Failure) {
        switch failure {
        case .launchFailed(let message): self = .launchFailed(message: message)
        case .exited(let status, let message): self = .commandFailed(status: status, message: message)
        case .timedOut(let seconds): self = .timedOut(seconds: seconds)
        }
    }
}

extension AWSCLIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Strata couldn\u{2019}t find the AWS CLI."
        case .launchFailed(let message):
            return "The AWS CLI couldn\u{2019}t be started: \(message)"
        case .commandFailed(_, let message):
            return message
        case .malformedResponse:
            return "The AWS CLI returned credentials Strata couldn\u{2019}t read."
        case .credentialsExpired(let profile):
            return "The sign-in for the \u{201C}\(profile)\u{201D} profile has expired."
        case .timedOut(let seconds):
            return "The AWS CLI didn\u{2019}t answer within \(seconds) seconds."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .binaryNotFound:
            return "Install it with \u{201C}brew install awscli\u{201D} (version 2.13 or later). If it\u{2019}s installed somewhere unusual, set its location in Settings \u{25B8} Accounts."
        case .commandFailed:
            return "Check that \u{201C}aws configure export-credentials\u{201D} works for this profile in Terminal. Strata needs AWS CLI 2.13 or later."
        case .malformedResponse:
            return "Updating the AWS CLI may help."
        case .credentialsExpired(let profile):
            return "Run \u{201C}aws sso login --profile \(profile)\u{201D} in Terminal, then try again."
        case .timedOut, .launchFailed:
            return "Check that the AWS CLI works in Terminal."
        }
    }
}

/// Supplies SigV4 credentials by shelling out to
/// `aws configure export-credentials --profile <name> --format process`.
///
/// This is the S3 counterpart to `AzureCLITokenProvider`, and the reason Strata does
/// not need the AWS SDK. That one subcommand (AWS CLI v2.13+) runs the whole standard
/// credential chain — static keys, SSO with its token cache, assume-role with MFA,
/// credential_process, instance metadata — and hands back the resolved credentials as
/// JSON. Reimplementing that chain would be a large amount of security-sensitive code
/// to maintain; asking the tool the user has already configured is both less work and
/// more correct, since it stays in step with however they set things up.
///
/// As with `az`, the CLI is a Python program with a noticeable cold start, so
/// credentials are cached, refreshed shortly before expiry, and shared by concurrent
/// callers. Finding and running the binary is `CLIProcess`'s job.
actor AWSCLICredentialProvider: AWSCredentialSource {

    struct Configuration: Sendable {
        /// Where `aws` is, for this provider only. Nil falls back to the Settings ▸
        /// Accounts choice, then to searching the usual install locations.
        var explicitBinaryPath: String?
        /// Which profile to resolve. Defaults to `AWS_PROFILE`, else `default`.
        var profile: String
        /// Refresh this long before expiry, so a caller never receives credentials
        /// that die mid-request.
        var refreshMargin: TimeInterval = 300

        init(
            explicitBinaryPath: String? = nil,
            profile: String = AWSAuth.defaultProfileName,
            refreshMargin: TimeInterval = 300
        ) {
            self.explicitBinaryPath = explicitBinaryPath
            self.profile = profile
            self.refreshMargin = refreshMargin
        }
    }

    private let configuration: Configuration
    /// Injectable so tests can drive the decode/caching logic with canned CLI output
    /// instead of requiring an installed, configured AWS CLI.
    private let runner: @Sendable ([String]) async throws -> Data
    private var cached: AWSCredentials?
    /// The fetch in progress, so concurrent callers share one `aws` run.
    private var refreshing: Task<AWSCredentials, any Error>?

    init(
        configuration: Configuration = Configuration(),
        runner: (@Sendable ([String]) async throws -> Data)? = nil
    ) {
        self.configuration = configuration
        self.runner = runner ?? { arguments in
            let explicitPath = configuration.explicitBinaryPath ?? StrataDefaults.awsCLIPath
            guard let binary = await CLIProcess.locate("aws", explicitPath: explicitPath) else {
                throw AWSCLIError.binaryNotFound
            }
            do {
                return try await CLIProcess.run(binary: binary, arguments: arguments)
            } catch let failure as CLIProcess.Failure {
                throw AWSCLIError(failure)
            }
        }
    }

    func credentials(asOf now: Date = Date()) async throws -> AWSCredentials {
        if let cached, cached.isValid(asOf: now, refreshMargin: configuration.refreshMargin) {
            return cached
        }
        let fresh: AWSCredentials
        if let refreshing {
            fresh = try await refreshing.value
        } else {
            let task = Task { try await fetch() }
            refreshing = task
            defer { refreshing = nil }
            fresh = try await task.value
        }
        // An expired result means the underlying session is gone — surfaced as its own
        // error so the UI can say "run aws sso login" instead of "access denied" after
        // the first signed request fails.
        guard fresh.isValid(asOf: now, refreshMargin: 0) else {
            cached = nil
            throw AWSCLIError.credentialsExpired(profile: configuration.profile)
        }
        cached = fresh
        return fresh
    }

    /// Drops the cache (e.g. after a 403), forcing a fresh resolve next call.
    func invalidate() async {
        cached = nil
    }

    // MARK: - Fetching

    private func fetch() async throws -> AWSCredentials {
        let output = try await runner([
            "configure", "export-credentials",
            "--profile", configuration.profile,
            "--format", "process",
        ])
        do {
            return try JSONDecoder().decode(ExportedCredentials.self, from: output).makeCredentials()
        } catch is DecodingError {
            throw AWSCLIError.malformedResponse
        }
    }
}

/// Decodes `aws configure export-credentials --format process`, which emits the
/// credential_process schema: `Version`, `AccessKeyId`, `SecretAccessKey`,
/// `SessionToken`, `Expiration`.
private struct ExportedCredentials: Decodable {
    let accessKeyID: String
    let secretAccessKey: String
    let sessionToken: String?
    let expiration: String?

    enum CodingKeys: String, CodingKey {
        case accessKeyID = "AccessKeyId"
        case secretAccessKey = "SecretAccessKey"
        case sessionToken = "SessionToken"
        case expiration = "Expiration"
    }

    func makeCredentials() throws -> AWSCredentials {
        var expiry: Date?
        if let expiration, !expiration.isEmpty {
            // The schema specifies ISO 8601. Long-lived keys omit the field entirely,
            // so only a *present but unparseable* value is a problem worth failing on.
            guard let parsed = Self.parseISO8601(expiration) else {
                throw AWSCLIError.malformedResponse
            }
            expiry = parsed
        }
        return AWSCredentials(
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken.flatMap { $0.isEmpty ? nil : $0 },
            expiration: expiry
        )
    }

    /// Tolerates both the fractional-second and whole-second spellings; the CLI has
    /// emitted each over time.
    private static func parseISO8601(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
