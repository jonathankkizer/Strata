import Testing
import Foundation
@testable import Strata

/// `S3Provider`'s own logic is thin — it delegates to the REST client — except for one
/// thing worth pinning: it has to find buckets that live in a region other than the
/// profile's, and it has to stop asking once it knows.
/// `.serialized` because the stub's request log is shared static state that each test
/// resets — Swift Testing runs a suite's tests in parallel by default, and three of
/// these use the same bucket, so without it they would count each other's requests.
@Suite("S3 provider region handling", .serialized)
struct S3ProviderRegionTests {

    private struct StubCredentials: AWSCredentialSource {
        func credentials(asOf now: Date) async throws -> AWSCredentials {
            AWSCredentials(accessKeyID: "AKIA", secretAccessKey: "secret", sessionToken: nil, expiration: nil)
        }
    }

    private func provider(region: String = "us-east-1") -> S3Provider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegionStubURLProtocol.self]
        return S3Provider(
            profile: "test",
            region: region,
            credentialSource: StubCredentials(),
            session: URLSession(configuration: configuration)
        )
    }

    /// A bucket in the profile's own region needs exactly one request — no speculative
    /// `GetBucketLocation` before every first use.
    @Test("A same-region bucket costs a single request")
    func sameRegionIsOneRequest() async throws {
        RegionStubURLProtocol.reset()
        let objects = try await provider().listObjects(
            in: StorageContainer(name: "home-bucket"),
            prefix: ""
        )
        #expect(objects.map(\.key) == ["home.txt"])
        #expect(RegionStubURLProtocol.requestCount(for: "home-bucket") == 1)
    }

    /// The interesting path: the first attempt lands in the wrong region, S3 says where
    /// the bucket really is, and the operation is retried there rather than failing.
    @Test("A bucket in another region is found by retrying where S3 says")
    func retriesInTheReportedRegion() async throws {
        RegionStubURLProtocol.reset()
        let objects = try await provider().listObjects(
            in: StorageContainer(name: "away-bucket"),
            prefix: ""
        )
        #expect(objects.map(\.key) == ["away.txt"])
        // One rejected attempt plus one that succeeded.
        #expect(RegionStubURLProtocol.requestCount(for: "away-bucket") == 2)
        #expect(RegionStubURLProtocol.regionsSeen(for: "away-bucket") == ["us-east-1", "eu-west-1"])
    }

    /// Learning is the point — a second operation on the same bucket must not repeat the
    /// failed round trip.
    @Test("The learned region is reused for later operations")
    func remembersTheRegion() async throws {
        RegionStubURLProtocol.reset()
        let provider = provider()
        _ = try await provider.listObjects(in: StorageContainer(name: "away-bucket"), prefix: "")
        _ = try await provider.listObjects(in: StorageContainer(name: "away-bucket"), prefix: "")
        _ = try await provider.listObjects(in: StorageContainer(name: "away-bucket"), prefix: "")

        // 2 for the first call (miss + retry), then 1 each.
        #expect(RegionStubURLProtocol.requestCount(for: "away-bucket") == 4)
    }

    /// A different provider instance hasn't learned anything, so the cache is per
    /// connection rather than global — which is what keeps two windows on different
    /// profiles from teaching each other wrong answers.
    @Test("The cache doesn't leak between providers")
    func cacheIsPerProvider() async throws {
        RegionStubURLProtocol.reset()
        _ = try await provider().listObjects(in: StorageContainer(name: "away-bucket"), prefix: "")
        _ = try await provider().listObjects(in: StorageContainer(name: "away-bucket"), prefix: "")
        #expect(RegionStubURLProtocol.requestCount(for: "away-bucket") == 4)
    }

    /// A wrong-region answer that doesn't actually name a different region would loop
    /// forever if it were retried, so it has to surface.
    @Test("A redirect with no usable region is not retried")
    func unhelpfulRedirectSurfaces() async throws {
        RegionStubURLProtocol.reset()
        await #expect(throws: (any Error).self) {
            _ = try await provider().listObjects(in: StorageContainer(name: "confused-bucket"), prefix: "")
        }
        #expect(RegionStubURLProtocol.requestCount(for: "confused-bucket") == 1)
    }

    /// Errors that aren't about regions must pass straight through rather than being
    /// swallowed by the retry.
    @Test("A permissions failure isn't retried")
    func permissionFailureIsNotRetried() async throws {
        RegionStubURLProtocol.reset()
        await #expect(throws: StorageProviderError.dataPlaneForbidden(account: "denied-bucket")) {
            _ = try await provider().listObjects(in: StorageContainer(name: "denied-bucket"), prefix: "")
        }
        #expect(RegionStubURLProtocol.requestCount(for: "denied-bucket") == 1)
    }

    @Test("Object URLs are the canonical s3:// form")
    func objectURLs() {
        let url = provider().objectURL(forKey: "logs/app.log", in: StorageContainer(name: "my-bucket"))
        #expect(url?.absoluteString == "s3://my-bucket/logs/app.log")
    }
}

/// Answers listings per bucket, rejecting `away-bucket` unless the request was signed
/// for eu-west-1, and records which regions were attempted.
final class RegionStubURLProtocol: URLProtocol {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var attempts: [String: [String]] = [:]

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        attempts = [:]
    }

    static func requestCount(for bucket: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts[bucket]?.count ?? 0
    }

    static func regionsSeen(for bucket: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return attempts[bucket] ?? []
    }

    private static func record(_ region: String, for bucket: String) {
        lock.lock()
        defer { lock.unlock() }
        attempts[bucket, default: []].append(region)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let bucket = String(host.prefix(while: { $0 != "." }))
        // The signed region is recoverable from the credential scope in Authorization.
        let region = Self.signedRegion(in: request.value(forHTTPHeaderField: "Authorization") ?? "")
        Self.record(region, for: bucket)

        let (status, headers, body) = Self.response(bucket: bucket, signedRegion: region)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    /// `Credential=AKIA/20260803/eu-west-1/s3/aws4_request`
    private static func signedRegion(in authorization: String) -> String {
        let parts = authorization.split(separator: "/")
        guard parts.count >= 3 else { return "unknown" }
        return String(parts[2])
    }

    private static func response(bucket: String, signedRegion: String) -> (Int, [String: String], String) {
        switch bucket {
        case "home-bucket":
            return (200, [:], listing(key: "home.txt"))
        case "away-bucket":
            guard signedRegion == "eu-west-1" else {
                // Exactly what live S3 does: 403 carrying the real region, not a 301.
                return (403, ["x-amz-bucket-region": "eu-west-1"], "<Error><Code>AccessDenied</Code></Error>")
            }
            return (200, [:], listing(key: "away.txt"))
        case "confused-bucket":
            // Claims a redirect but names the region we already used.
            return (403, ["x-amz-bucket-region": signedRegion], "<Error><Code>AccessDenied</Code></Error>")
        default:
            return (403, [:], "<Error><Code>AccessDenied</Code></Error>")
        }
    }

    private static func listing(key: String) -> String {
        """
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents><Key>\(key)</Key><Size>1</Size></Contents>
        </ListBucketResult>
        """
    }
}

@Suite("Provider factory")
struct ProviderFactoryTests {

    @Test("Builds the right provider for each cloud")
    func buildsPerKind() {
        let azure = ProviderFactory.make(for: .azure("acct"))
        #expect(azure.kind == .azureBlob)
        #expect(azure.displayName == "acct")

        let s3 = ProviderFactory.make(for: .s3(profile: "sandbox"))
        #expect(s3.kind == .s3)
        #expect(s3.displayName == "sandbox")
    }

    /// The provider's `account` round-trips back to what it was built from, which is
    /// what keeps favorites and the preview-cache key consistent.
    @Test("A built provider reports the account it came from")
    func accountRoundTrips() {
        for account in [ProviderAccount.azure("acct"), .s3(profile: "sandbox")] {
            #expect(ProviderFactory.make(for: account).account == account)
        }
    }
}
