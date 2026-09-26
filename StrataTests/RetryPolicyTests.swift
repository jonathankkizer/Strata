import Testing
import Foundation
@testable import Strata

/// TODO.md R1: transient failures are retried with backoff instead of failing the
/// whole transfer.
@Suite("Retry policy")
struct RetryPolicyTests {

    private struct Permanent: Error, Equatable {}

    private let instant = RetryPolicy(maxAttempts: 4, baseDelay: .milliseconds(500), maxDelay: .seconds(20))

    @Test("Waits grow exponentially and stop at the cap")
    func exponentialDelay() {
        #expect(instant.delay(afterAttempt: 1, retryAfter: nil, random: 1) == .milliseconds(500))
        #expect(instant.delay(afterAttempt: 2, retryAfter: nil, random: 1) == .seconds(1))
        #expect(instant.delay(afterAttempt: 3, retryAfter: nil, random: 1) == .seconds(2))
        #expect(instant.delay(afterAttempt: 12, retryAfter: nil, random: 1) == .seconds(20))
    }

    /// Full jitter: a failure shared by many transfers mustn't bring them all back at
    /// the same instant.
    @Test("The wait is a random fraction of the bound")
    func jitter() {
        #expect(instant.delay(afterAttempt: 3, retryAfter: nil, random: 0.25) == .milliseconds(500))
        #expect(instant.delay(afterAttempt: 3, retryAfter: nil, random: 0) == .zero)
    }

    @Test("The service's Retry-After wins, within the cap")
    func retryAfterWins() {
        #expect(instant.delay(afterAttempt: 1, retryAfter: .seconds(7), random: 0) == .seconds(7))
        #expect(instant.delay(afterAttempt: 1, retryAfter: .seconds(3600), random: 0) == .seconds(20))
    }

    @Test("Reads Retry-After in seconds")
    func parsesRetryAfter() {
        let response = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 503, httpVersion: nil, headerFields: ["Retry-After": "12"])!
        #expect(RetryPolicy.retryAfter(from: response) == .seconds(12))
    }

    @Test("A transient failure is retried until it succeeds")
    func retriesThenSucceeds() async throws {
        let attempts = Counter()
        let result = try await instant.run(sleep: { _ in }, random: { 0 }) {
            if attempts.next() < 2 { throw TransientFailure(underlying: Permanent(), retryAfter: nil) }
            return "ok"
        }
        #expect(result == "ok")
        #expect(attempts.value == 3)
    }

    @Test("After the last attempt, the real error comes out")
    func givesUp() async {
        let attempts = Counter()
        await #expect(throws: Permanent()) {
            try await instant.run(sleep: { _ in }, random: { 0 }) {
                _ = attempts.next()
                throw TransientFailure(underlying: Permanent(), retryAfter: nil)
            }
        }
        #expect(attempts.value == 4)
    }

    @Test("A dropped connection is retried; a cancelled one is not")
    func urlErrors() async {
        let dropped = Counter()
        _ = try? await instant.run(sleep: { _ in }, random: { 0 }) {
            _ = dropped.next()
            throw URLError(.networkConnectionLost)
        }
        #expect(dropped.value == 4)

        let cancelled = Counter()
        _ = try? await instant.run(sleep: { _ in }, random: { 0 }) {
            _ = cancelled.next()
            throw URLError(.cancelled)
        }
        #expect(cancelled.value == 1)
    }

    @Test("Other errors are not retried")
    func permanentNotRetried() async {
        let attempts = Counter()
        await #expect(throws: Permanent()) {
            try await instant.run(sleep: { _ in }, random: { 0 }) {
                _ = attempts.next()
                throw Permanent()
            }
        }
        #expect(attempts.value == 1)
    }

    // MARK: - Through the clients

    private func quickPolicy() -> RetryPolicy { RetryPolicy(maxAttempts: 4, baseDelay: .milliseconds(1), maxDelay: .milliseconds(5)) }

    @Test("Azure: ServerBusy is ridden out")
    func azureBusy() async throws {
        let account = BusyStubURLProtocol.uniqueHost(prefix: "busy")
        let client = AzureBlobRESTClient(
            endpoint: AzureStorageEndpoint(account: account),
            tokenSource: FixedAzureToken(),
            session: BusyStubURLProtocol.session(),
            retryPolicy: quickPolicy()
        )
        try await client.deleteBlob(container: "c", key: "a.txt")
        #expect(BusyStubURLProtocol.requests(forHost: "\(account).blob.core.windows.net").count == 3)
    }

    @Test("S3: SlowDown is ridden out")
    func s3SlowDown() async throws {
        let bucket = BusyStubURLProtocol.uniqueHost(prefix: "busy")
        let client = S3RESTClient(
            endpoint: S3Endpoint(region: "us-west-2"),
            credentialSource: FixedAWSCredentials(),
            session: BusyStubURLProtocol.session(),
            retryPolicy: quickPolicy()
        )
        try await client.deleteObject(bucket: bucket, key: "a.txt")
        #expect(BusyStubURLProtocol.requests(forHost: "\(bucket).s3.us-west-2.amazonaws.com").count == 3)
    }

    /// A retry after a lost response would start a second upload and orphan the first.
    @Test("S3: starting a multipart upload is never retried")
    func createNotRetried() async {
        let bucket = BusyStubURLProtocol.uniqueHost(prefix: "busy")
        let client = S3RESTClient(
            endpoint: S3Endpoint(region: "us-west-2"),
            credentialSource: FixedAWSCredentials(),
            session: BusyStubURLProtocol.session(),
            retryPolicy: quickPolicy()
        )
        _ = try? await client.createMultipartUpload(bucket: bucket, key: "big.bin", contentType: nil)
        #expect(BusyStubURLProtocol.requests(forHost: "\(bucket).s3.us-west-2.amazonaws.com").count == 1)
    }
}

// MARK: - Fixtures

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    /// Returns the count before incrementing.
    func next() -> Int { lock.withLock { defer { count += 1 }; return count } }
    var value: Int { lock.withLock { count } }
}

private struct FixedAzureToken: AzureTokenSource {
    func token(asOf now: Date) async throws -> AzureAccessToken {
        AzureAccessToken(accessToken: "t", expiresOn: now.addingTimeInterval(3600), tenant: nil, subscription: nil)
    }
}

private struct FixedAWSCredentials: AWSCredentialSource {
    func credentials(asOf now: Date) async throws -> AWSCredentials {
        AWSCredentials(accessKeyID: "AKIA", secretAccessKey: "s", sessionToken: nil, expiration: nil)
    }
}

/// `busy…` hosts answer 503 (with the cloud's own busy code) to the first two
/// requests, then succeed.
final class BusyStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [String: [String]] = [:]

    static func uniqueHost(prefix: String) -> String {
        prefix + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BusyStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func requests(forHost host: String) -> [String] {
        lock.withLock { seen[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let count = Self.lock.withLock { () -> Int in
            Self.seen[host, default: []].append(request.httpMethod ?? "GET")
            return Self.seen[host]!.count
        }
        let isAzure = host.hasSuffix("blob.core.windows.net")
        let status = count <= 2 ? 503 : (isAzure ? 202 : 204)
        let body = count <= 2 ? (isAzure ? "<Error><Code>ServerBusy</Code></Error>" : "<Error><Code>SlowDown</Code></Error>") : ""
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
