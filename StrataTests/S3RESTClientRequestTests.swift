import Testing
import Foundation
@testable import Strata

/// Drives the real `S3RESTClient` over a stubbed transport, so the request it *builds*
/// and the paging loop are covered rather than only the parsing helpers. No network.
///
/// Requests are recorded per bucket, and every test uses a unique bucket name, so the
/// recorder needs no reset between the parallel tests Swift Testing runs.
@Suite("S3 REST client requests")
struct S3RESTClientRequestTests {

    private struct StubCredentials: AWSCredentialSource {
        func credentials(asOf now: Date) async throws -> AWSCredentials {
            AWSCredentials(
                accessKeyID: "AKIAEXAMPLE",
                secretAccessKey: "secret",
                sessionToken: "TOKEN",
                expiration: nil
            )
        }
    }

    private func makeClient(region: String = "us-west-2") -> S3RESTClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [S3StubURLProtocol.self]
        return S3RESTClient(
            endpoint: S3Endpoint(region: region),
            credentialSource: StubCredentials(),
            session: URLSession(configuration: configuration)
        )
    }

    // MARK: - Request shape

    @Test("A listing request carries the ListObjectsV2 parameters")
    func listingRequestShape() async throws {
        _ = try await makeClient().listObjectsPage(bucket: "shape-bucket", prefix: "logs/")

        let request = try #require(S3RequestRecorder.shared.requests(for: "shape-bucket").first)
        // Split rather than nested: a `#require` inside a `#require` is a recursive
        // macro expansion and won't compile.
        let url = try #require(request.url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })

        #expect(values["list-type"] == "2")
        #expect(values["prefix"] == "logs/")
        #expect(values["delimiter"] == "/")
        #expect(values["max-keys"] == "1000")
        #expect(request.httpMethod == "GET")
    }

    /// Every request has to be signed, and a temporary credential's token has to travel
    /// with it — both are silent 403s if missed.
    @Test("Requests are signed and carry the session token")
    func requestsAreSigned() async throws {
        _ = try await makeClient().listObjectsPage(bucket: "signed-bucket", prefix: "")

        let request = try #require(S3RequestRecorder.shared.requests(for: "signed-bucket").first)
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.contains("AWS4-HMAC-SHA256"))
        #expect(authorization.contains("/us-west-2/s3/aws4_request"))
        #expect(request.value(forHTTPHeaderField: "x-amz-security-token") == "TOKEN")
        #expect(request.value(forHTTPHeaderField: "x-amz-content-sha256") != nil)
        #expect(request.value(forHTTPHeaderField: "x-amz-date") != nil)
    }

    @Test("A prefix is omitted when empty rather than sent blank")
    func emptyPrefixOmitted() async throws {
        _ = try await makeClient().listObjectsPage(bucket: "noprefix-bucket", prefix: "")
        let request = try #require(S3RequestRecorder.shared.requests(for: "noprefix-bucket").first)
        let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains { $0.name == "prefix" } == false)
    }

    // MARK: - Paging

    /// S3 caps a response at 1000 keys. Without following the continuation token, a
    /// large folder would silently appear to end early — the kind of wrong that looks
    /// like working software.
    @Test("Follows continuation tokens across every page")
    func followsPaging() async throws {
        let objects = try await makeClient().listAllObjects(bucket: "paged-bucket", prefix: "")

        #expect(objects.map(\.key) == ["a.txt", "b.txt", "c.txt"])
        let requests = S3RequestRecorder.shared.requests(for: "paged-bucket")
        #expect(requests.count == 2)
        // The second request must carry the token from the first.
        let secondQuery = URLComponents(url: try #require(requests[1].url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(secondQuery.contains { $0.name == "continuation-token" && $0.value == "PAGE2" })
    }

    /// A truncated page with no token would otherwise loop forever.
    @Test("Stops when a truncated page reports no token")
    func stopsOnTruncatedWithoutToken() async throws {
        let objects = try await makeClient().listAllObjects(bucket: "brokenpage-bucket", prefix: "")
        #expect(objects.map(\.key) == ["only.txt"])
        #expect(S3RequestRecorder.shared.requests(for: "brokenpage-bucket").count == 1)
    }

    // MARK: - Other operations

    @Test("HEAD returns decoded metadata")
    func headObject() async throws {
        let metadata = try await makeClient().headObject(bucket: "head-bucket", key: "logs/app.log")
        #expect(metadata.size == 66560)
        #expect(metadata.contentType == "text/plain")
        #expect(metadata.custom == ["owner": "data-team"])

        let request = try #require(S3RequestRecorder.shared.requests(for: "head-bucket").first)
        #expect(request.httpMethod == "HEAD")
        #expect(request.url?.path == "/logs/app.log")
    }

    @Test("ListBuckets goes to the service endpoint")
    func listBuckets() async throws {
        let buckets = try await makeClient().listBuckets()
        #expect(buckets.map(\.name) == ["alpha", "beta"])
    }

    @Test("GetBucketLocation prefers the region header")
    func bucketRegionFromHeader() async throws {
        #expect(try await makeClient().bucketRegion(bucket: "region-bucket") == "eu-central-1")
    }

    /// An empty LocationConstraint means us-east-1, and `EU` is a legacy spelling of
    /// eu-west-1 — both would otherwise be read as a region that doesn't exist.
    @Test("An empty location constraint means us-east-1")
    func bucketRegionEmptyConstraint() async throws {
        #expect(try await makeClient().bucketRegion(bucket: "legacy-bucket") == "eu-west-1")
        #expect(try await makeClient().bucketRegion(bucket: "useast-bucket") == "us-east-1")
    }

    @Test("An access-denied response maps to a forbidden error")
    func accessDeniedMaps() async throws {
        await #expect(throws: StorageProviderError.dataPlaneForbidden(account: "denied-bucket")) {
            _ = try await makeClient().listObjectsPage(bucket: "denied-bucket", prefix: "")
        }
    }

    @Test("A redirect surfaces the correct region so it can be retried")
    func redirectSurfacesRegion() async throws {
        do {
            _ = try await makeClient().listObjectsPage(bucket: "moved-bucket", prefix: "")
            Issue.record("expected a throw")
        } catch let S3Error.wrongRegion(_, correctRegion) {
            #expect(correctRegion == "ap-southeast-2")
        }
    }
}

// MARK: - Stub transport

/// Records the requests each bucket saw, so tests can assert on what was built.
final class S3RequestRecorder: @unchecked Sendable {
    static let shared = S3RequestRecorder()

    private let lock = NSLock()
    private var recorded: [String: [URLRequest]] = [:]

    func record(_ request: URLRequest, bucket: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded[bucket, default: []].append(request)
    }

    func requests(for bucket: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded[bucket] ?? []
    }
}

/// Serves canned S3 responses chosen by the bucket in the request, and records what it
/// was asked for. The bucket may be in the host (virtual-hosted) or the first path
/// component (path style), so both are checked.
private final class S3StubURLProtocol: URLProtocol {

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let bucket = Self.bucket(in: url)
        if !bucket.isEmpty {
            S3RequestRecorder.shared.record(request, bucket: bucket)
        }

        let (status, headers, body) = Self.response(
            bucket: bucket,
            query: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        )
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func bucket(in url: URL) -> String {
        if let host = url.host, host.hasSuffix(".s3.us-west-2.amazonaws.com") {
            return String(host.dropLast(".s3.us-west-2.amazonaws.com".count))
        }
        return url.pathComponents.dropFirst().first ?? ""
    }

    private static func response(
        bucket: String,
        query: [URLQueryItem]
    ) -> (Int, [String: String], String) {
        let token = query.first { $0.name == "continuation-token" }?.value

        switch bucket {
        case "denied-bucket":
            return (403, [:], "<Error><Code>AccessDenied</Code></Error>")
        case "moved-bucket":
            return (301, ["x-amz-bucket-region": "ap-southeast-2"], "<Error><Code>PermanentRedirect</Code></Error>")
        case "region-bucket":
            return (200, ["x-amz-bucket-region": "eu-central-1"], "<LocationConstraint>us-east-2</LocationConstraint>")
        case "legacy-bucket":
            return (200, [:], "<LocationConstraint>EU</LocationConstraint>")
        case "useast-bucket":
            return (200, [:], "<LocationConstraint></LocationConstraint>")
        case "head-bucket":
            return (200, [
                "Content-Length": "66560",
                "Content-Type": "text/plain",
                "ETag": "\"abc\"",
                "x-amz-meta-owner": "data-team",
            ], "")
        case "paged-bucket":
            if token == "PAGE2" {
                return (200, [:], listing(keys: ["c.txt"], truncated: false, nextToken: nil))
            }
            return (200, [:], listing(keys: ["a.txt", "b.txt"], truncated: true, nextToken: "PAGE2"))
        case "brokenpage-bucket":
            // Truncated but with no token — the loop must not spin.
            return (200, [:], listing(keys: ["only.txt"], truncated: true, nextToken: nil))
        case "":
            return (200, [:], """
                <ListAllMyBucketsResult><Buckets>
                  <Bucket><Name>alpha</Name></Bucket>
                  <Bucket><Name>beta</Name></Bucket>
                </Buckets></ListAllMyBucketsResult>
                """)
        default:
            return (200, [:], listing(keys: ["file.txt"], truncated: false, nextToken: nil))
        }
    }

    private static func listing(keys: [String], truncated: Bool, nextToken: String?) -> String {
        let contents = keys.map {
            "<Contents><Key>\($0)</Key><Size>10</Size><StorageClass>STANDARD</StorageClass></Contents>"
        }.joined()
        let tokenElement = nextToken.map { "<NextContinuationToken>\($0)</NextContinuationToken>" } ?? ""
        return """
            <ListBucketResult>
              <IsTruncated>\(truncated)</IsTruncated>
              \(tokenElement)
              \(contents)
            </ListBucketResult>
            """
    }
}
