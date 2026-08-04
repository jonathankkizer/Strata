import Foundation

/// A set of SigV4 signing credentials, with the expiry that applies when they came
/// from STS (SSO, assume-role, instance metadata). Long-lived user keys never expire,
/// which is what a nil `expiration` means.
struct AWSCredentials: Sendable, Equatable {
    var accessKeyID: String
    var secretAccessKey: String
    /// Present for temporary credentials; signed requests must carry it in
    /// `x-amz-security-token`.
    var sessionToken: String?
    var expiration: Date?

    func isValid(asOf now: Date, refreshMargin: TimeInterval) -> Bool {
        guard let expiration else { return true }
        return expiration.timeIntervalSince(now) > refreshMargin
    }
}

/// Anything that can supply signing credentials. The S3 client depends on this rather
/// than a concrete source, so the CLI piggyback, a future static-key entry, and an
/// SSO-specific path are interchangeable — the same shape as `AzureTokenSource`.
protocol AWSCredentialSource: Sendable {
    func credentials(asOf now: Date) async throws -> AWSCredentials
}

enum AWSAuth {
    /// Candidate paths for the `aws` binary. A GUI app launched from Finder does not
    /// inherit the shell PATH, so the CLI has to be resolved explicitly — the same
    /// problem, and the same fix, as `az`.
    static let awsCLISearchPaths = [
        "/opt/homebrew/bin/aws",
        "/usr/local/bin/aws",
        "/usr/bin/aws",
    ]

    /// Where the CLI keeps its configuration. Read directly only to enumerate profile
    /// names for the picker — never to resolve credentials, which is the CLI's job.
    static var configFileURL: URL {
        overriddenPath(from: "AWS_CONFIG_FILE")
            ?? homeDirectory.appendingPathComponent(".aws/config")
    }

    static var credentialsFileURL: URL {
        overriddenPath(from: "AWS_SHARED_CREDENTIALS_FILE")
            ?? homeDirectory.appendingPathComponent(".aws/credentials")
    }

    /// The default profile name, honouring `AWS_PROFILE` the way every AWS tool does.
    static var defaultProfileName: String {
        ProcessInfo.processInfo.environment["AWS_PROFILE"].flatMap {
            $0.isEmpty ? nil : $0
        } ?? "default"
    }

    private static var homeDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
    }

    private static func overriddenPath(from variable: String) -> URL? {
        guard let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }
}
