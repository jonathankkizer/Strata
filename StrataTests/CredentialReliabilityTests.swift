import Testing
import Foundation
@testable import Strata

/// Signing in through the CLIs, and saying something useful when that fails.
/// TODO.md items R2–R6.

// MARK: - Error wording

@Suite("Error wording")
struct StorageErrorTextTests {

    /// This used to tell an S3 user to grant an Azure role.
    @Test("An S3 access denial talks about IAM, not Azure roles")
    func s3Forbidden() {
        let message = StorageErrorText.message(for: StorageProviderError.dataPlaneForbidden(account: "logs"), kind: .s3)
        #expect(message.full.contains("IAM"))
        #expect(!message.full.contains("Storage Blob Data"))
    }

    @Test("An Azure data-plane denial names the role that's missing")
    func azureForbidden() {
        let message = StorageErrorText.message(for: StorageProviderError.dataPlaneForbidden(account: "acct"), kind: .azureBlob)
        #expect(message.full.contains("Storage Blob Data Reader"))
    }

    @Test("Each cloud's sign-in failure points at its own CLI")
    func unauthorizedByCloud() {
        #expect(StorageErrorText.message(for: StorageProviderError.unauthorized, kind: .azureBlob).full.contains("az login"))
        #expect(StorageErrorText.message(for: StorageProviderError.unauthorized, kind: .s3).full.contains("aws sso login"))
    }

    /// Was "Strata.AzureCLIError error 0." — the most common first-run failure.
    @Test("A missing CLI says what to install")
    func missingCLI() {
        let azure = StorageErrorText.message(for: AzureCLIError.binaryNotFound, kind: .azureBlob)
        #expect(azure.summary == "Strata couldn\u{2019}t find the Azure CLI.")
        #expect(azure.suggestion?.contains("brew install azure-cli") == true)
        let aws = StorageErrorText.message(for: AWSCLIError.binaryNotFound, kind: .s3)
        #expect(aws.suggestion?.contains("brew install awscli") == true)
    }

    @Test("An expired SSO session names the command for its profile")
    func expiredSSO() {
        let message = StorageErrorText.message(for: AWSCLIError.credentialsExpired(profile: "dev"), kind: .s3)
        #expect(message.suggestion?.contains("aws sso login --profile dev") == true)
    }

    @Test("The CLI's own explanation is passed through")
    func commandFailure() {
        let error = AzureCLIError.commandFailed(status: 1, message: "Please run 'az login' to setup account.")
        #expect(StorageErrorText.summary(for: error, kind: .azureBlob) == "Please run 'az login' to setup account.")
    }
}

// MARK: - Error mapping

@Suite("Mapping service errors")
struct ServiceErrorMappingTests {

    /// A storage firewall answers 403 `AuthorizationFailure`; calling that a missing
    /// role sends people to IAM for a network setting.
    @Test("Azure's firewall refusal is not reported as a missing role")
    func azureFirewall() {
        let error = AzureBlobRESTClient.error(status: 403, body: "<Error><Code>AuthorizationFailure</Code></Error>", account: "acct")
        #expect(error as? StorageProviderError == .networkRestricted(account: "acct"))
    }

    @Test("Azure's refusal of the token itself is a sign-in problem")
    func azureAuthentication() {
        let error = AzureBlobRESTClient.error(status: 403, body: "<Error><Code>AuthenticationFailed</Code></Error>", account: "acct")
        #expect(error as? StorageProviderError == .unauthorized)
    }

    @Test("Azure's missing data role is still reported as one")
    func azureRole() {
        let error = AzureBlobRESTClient.error(status: 403, body: "<Error><Code>AuthorizationPermissionMismatch</Code></Error>", account: "acct")
        #expect(error as? StorageProviderError == .dataPlaneForbidden(account: "acct"))
    }

    @Test("S3's clock-skew 403 is about the clock")
    func s3ClockSkew() {
        let error = S3RESTClient.error(
            status: 403,
            body: "<Error><Code>RequestTimeTooSkewed</Code></Error>",
            bucket: "b",
            response: HTTPURLResponse(url: URL(string: "https://b.s3.amazonaws.com")!, statusCode: 403, httpVersion: nil, headerFields: [:])!,
            signedRegion: "us-east-1"
        )
        #expect(error as? StorageProviderError == .clockSkewed)
    }
}

// MARK: - Retrying after a refused token

@Suite("A refused token is dropped and retried once")
struct RejectedTokenRetryTests {

    @Test("Azure: a 401 invalidates the token and the request succeeds on the retry")
    func azureRetry() async throws {
        let account = RetryStubURLProtocol.uniqueHost(prefix: "once")
        let tokens = CountingAzureToken()
        let client = AzureBlobRESTClient(
            endpoint: AzureStorageEndpoint(account: account),
            tokenSource: tokens,
            session: RetryStubURLProtocol.session()
        )
        try await client.deleteBlob(container: "c", key: "a.txt")
        #expect(await tokens.invalidations == 1)
        #expect(RetryStubURLProtocol.count(forHost: "\(account).blob.core.windows.net") == 2)
    }

    @Test("Azure: a token refused twice is reported, not retried forever")
    func azureGivesUp() async throws {
        let account = RetryStubURLProtocol.uniqueHost(prefix: "never")
        let tokens = CountingAzureToken()
        let client = AzureBlobRESTClient(
            endpoint: AzureStorageEndpoint(account: account),
            tokenSource: tokens,
            session: RetryStubURLProtocol.session()
        )
        await #expect(throws: StorageProviderError.unauthorized) {
            try await client.deleteBlob(container: "c", key: "a.txt")
        }
        #expect(RetryStubURLProtocol.count(forHost: "\(account).blob.core.windows.net") == 2)
    }
}

// MARK: - One refresh at a time

@Suite("Concurrent callers share one credential refresh")
struct SharedRefreshTests {

    /// Each `aws` run is a Python cold start. Eight parallel deletes used to start eight.
    @Test("Eight simultaneous requests run the CLI once")
    func singleFlight() async throws {
        let runs = RunCounter()
        let provider = AWSCLICredentialProvider(
            configuration: .init(profile: "default"),
            runner: { _ in
                runs.increment()
                try await Task.sleep(for: .milliseconds(100))
                return Data(#"{"Version": 1, "AccessKeyId": "AKIA", "SecretAccessKey": "s"}"#.utf8)
            }
        )
        try await withThrowingTaskGroup(of: AWSCredentials.self) { group in
            for _ in 0..<8 { group.addTask { try await provider.credentials(asOf: Date()) } }
            for try await credentials in group { #expect(credentials.accessKeyID == "AKIA") }
        }
        #expect(runs.value == 1)
    }

    /// The protocol's default `invalidate()` once shadowed the actor's own, so the
    /// retry after a refused request called a no-op. Called through the protocol here,
    /// the way the REST clients call it.
    @Test("Invalidating through the protocol reaches the real cache")
    func invalidateThroughProtocol() async throws {
        let runs = RunCounter()
        let source: any AWSCredentialSource = AWSCLICredentialProvider(
            configuration: .init(profile: "default"),
            runner: { _ in
                runs.increment()
                return Data(#"{"Version": 1, "AccessKeyId": "AKIA", "SecretAccessKey": "s"}"#.utf8)
            }
        )
        _ = try await source.credentials(asOf: Date())
        await source.invalidate()
        _ = try await source.credentials(asOf: Date())
        #expect(runs.value == 2)
    }
}

// MARK: - Running the CLI

@Suite("Running a CLI")
struct CLIProcessTests {

    @Test("Returns standard output")
    func output() async throws {
        let data = try await CLIProcess.run(binary: "/bin/echo", arguments: ["hello"])
        #expect(String(data: data, encoding: .utf8) == "hello\n")
    }

    /// Reading only at exit deadlocks once output passes the pipe buffer (64 KB).
    @Test("More output than a pipe buffer holds doesn't deadlock")
    func largeOutput() async throws {
        let data = try await CLIProcess.run(binary: "/bin/sh", arguments: ["-c", "head -c 300000 /dev/zero"], timeout: .seconds(10))
        #expect(data.count == 300_000)
    }

    @Test("A failing command reports its status and what it wrote to stderr")
    func failure() async {
        await #expect(throws: CLIProcess.Failure.exited(status: 3, message: "nope")) {
            _ = try await CLIProcess.run(binary: "/bin/sh", arguments: ["-c", "echo nope >&2; exit 3"])
        }
    }

    /// A hung CLI used to hang every transfer waiting on its token.
    @Test("A command that hangs is stopped at the timeout")
    func timeout() async {
        let start = ContinuousClock.now
        await #expect(throws: CLIProcess.Failure.timedOut(seconds: 0)) {
            _ = try await CLIProcess.run(binary: "/bin/sleep", arguments: ["30"], timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("Cancelling the caller stops the command")
    func cancellation() async {
        let start = ContinuousClock.now
        let task = Task { try await CLIProcess.run(binary: "/bin/sleep", arguments: ["30"]) }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        _ = await task.result
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("An explicit path wins, and tildes are expanded")
    func explicitPath() async {
        #expect(await CLIProcess.locate("anything", explicitPath: "/bin/sh") == "/bin/sh")
    }

    /// A pipx or nix install needs its own directory on PATH to find its siblings,
    /// and a Finder-launched app's PATH has none of the usual ones.
    @Test("The CLI runs with its own directory and the usual ones on PATH")
    func path() throws {
        let path = try #require(CLIProcess.environment(forBinary: "/Users/me/.local/bin/aws")["PATH"])
        let directories = path.split(separator: ":").map(String.init)
        #expect(directories.first == "/Users/me/.local/bin")
        #expect(directories.contains("/opt/homebrew/bin"))
        #expect(directories.contains("/usr/bin"))
        #expect(Set(directories).count == directories.count)
    }
}

// MARK: - Fixtures

private actor CountingAzureToken: AzureTokenSource {
    private(set) var invalidations = 0

    func token(asOf now: Date) async throws -> AzureAccessToken {
        AzureAccessToken(accessToken: "t\(invalidations)", expiresOn: now.addingTimeInterval(3600), tenant: nil, subscription: nil)
    }

    func invalidate() async {
        invalidations += 1
    }
}

private final class RunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// `once…` hosts answer 401 to the first request and 202 after; `never…` hosts
/// always answer 401.
final class RetryStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    static func uniqueHost(prefix: String) -> String {
        prefix + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetryStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func count(forHost host: String) -> Int {
        lock.withLock { counts[host] ?? 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let seen = Self.lock.withLock { () -> Int in
            Self.counts[host, default: 0] += 1
            return Self.counts[host]!
        }
        let status = host.hasPrefix("never") || seen == 1 ? 401 : 202
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("Running a CLI, when something else keeps its output open")
struct CLIProcessBackgroundChildTests {

    /// A CLI can leave a background process holding its stdout. Reading to end of
    /// file would then wait for that process; the run must still come back.
    @Test("A background child holding the pipe doesn't hold up the result")
    func backgroundChild() async throws {
        let start = ContinuousClock.now
        let data = try await CLIProcess.run(binary: "/bin/sh", arguments: ["-c", "echo done; (sleep 20 &)"])
        #expect(String(data: data, encoding: .utf8) == "done\n")
        #expect(ContinuousClock.now - start < .seconds(6))
    }
}
