import Foundation

enum AWSCLIError: Error, Sendable, Equatable {
    case binaryNotFound
    case launchFailed(message: String)
    case commandFailed(status: Int32, message: String)
    case malformedResponse
    /// The CLI resolved the profile but the credentials it returned have already
    /// expired — an SSO session that needs `aws sso login` again.
    case credentialsExpired(profile: String)
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
/// The same two macOS realities apply as for `az`:
/// - a GUI app launched from Finder doesn't inherit the shell PATH, so the binary is
///   resolved explicitly (Preferences override first)
/// - the CLI is a Python program with a noticeable cold start, so credentials are
///   cached and refreshed shortly before expiry rather than fetched per request
actor AWSCLICredentialProvider: AWSCredentialSource {

    struct Configuration: Sendable {
        /// Preferences "Path to AWS CLI" override; tried before the search paths.
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

    init(
        configuration: Configuration = Configuration(),
        runner: (@Sendable ([String]) async throws -> Data)? = nil
    ) {
        self.configuration = configuration
        self.runner = runner ?? { arguments in
            let binary = try Self.resolveBinary(explicit: configuration.explicitBinaryPath)
            return try await Self.run(binary: binary, arguments: arguments)
        }
    }

    func credentials(asOf now: Date = Date()) async throws -> AWSCredentials {
        if let cached, cached.isValid(asOf: now, refreshMargin: configuration.refreshMargin) {
            return cached
        }
        let fresh = try await fetch()
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
    func invalidate() {
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

    private static func resolveBinary(explicit: String?) throws -> String {
        let fileManager = FileManager.default
        if let explicit, fileManager.isExecutableFile(atPath: explicit) {
            return explicit
        }
        for candidate in AWSAuth.awsCLISearchPaths where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw AWSCLIError.binaryNotFound
    }

    /// Runs the CLI and returns stdout. The credential JSON is well under the pipe
    /// buffer, so reading in the termination handler cannot deadlock.
    private static func run(binary: String, arguments: [String]) async throws -> Data {
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
                    continuation.resume(throwing: AWSCLIError.commandFailed(status: process.terminationStatus, message: message))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: AWSCLIError.launchFailed(message: error.localizedDescription))
            }
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
