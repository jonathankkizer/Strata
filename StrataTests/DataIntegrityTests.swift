import Testing
import Foundation
@testable import Strata

/// Regression tests for requests that reached the wrong object, or data that could be
/// silently lost. Each one pins a defect found in the September 2026 review; see
/// TODO.md items I1–I8.

// MARK: - Key and query encoding

@Suite("Strict percent-encoding")
struct StrictPercentEncodingTests {

    @Test("Every segment of a key survives, including empty ones")
    func keepsEmptySegments() {
        #expect(StrictPercentEncoding.key("logs/") == "logs/")
        #expect(StrictPercentEncoding.key("a//b") == "a//b")
        #expect(StrictPercentEncoding.key("/lead") == "/lead")
    }

    @Test("Reserved and non-ASCII characters are escaped")
    func escapesReserved() {
        #expect(StrictPercentEncoding.component("sp ace") == "sp%20ace")
        #expect(StrictPercentEncoding.component("C++") == "C%2B%2B")
        #expect(StrictPercentEncoding.component("a#b?c%d") == "a%23b%3Fc%25d")
        #expect(StrictPercentEncoding.component("ü") == "%C3%BC")
        #expect(StrictPercentEncoding.component("a-b_c.d~e") == "a-b_c.d~e")
    }
}

@Suite("Azure blob URLs")
struct AzureBlobURLTests {

    private let endpoint = AzureStorageEndpoint(account: "acct")

    /// `logs/` and `logs` are different blobs on a flat account. Collapsing one into
    /// the other is how deleting a folder also deleted a file with the folder's name.
    @Test("A folder key keeps its trailing slash")
    func trailingSlashKept() {
        #expect(endpoint.url(container: "c", key: "logs/").absoluteString
                == "https://acct.blob.core.windows.net/c/logs/")
        #expect(endpoint.url(container: "c", key: "logs").absoluteString
                == "https://acct.blob.core.windows.net/c/logs")
    }

    @Test("Doubled and awkward separators address the key as written")
    func awkwardKeys() {
        #expect(endpoint.url(container: "c", key: "a//b").absoluteString
                == "https://acct.blob.core.windows.net/c/a//b")
        #expect(endpoint.url(container: "c", key: "dir/sp ace #1.txt").absoluteString
                == "https://acct.blob.core.windows.net/c/dir/sp%20ace%20%231.txt")
    }

    /// Azure reads a bare `+` in a query as a space, so a `C++/` folder listed as empty.
    @Test("A plus in a listing prefix is escaped")
    func plusInQuery() {
        let url = endpoint.url(container: "c", query: [(name: "prefix", value: "C++/")])
        #expect(url.query(percentEncoded: true) == "prefix=C%2B%2B%2F")
    }

    @Test("Public object URLs use the same encoding")
    func providerObjectURL() {
        let provider = AzureBlobProvider(displayName: "acct", endpoint: endpoint, tokenSource: StubAzureToken())
        #expect(provider.objectURL(forKey: "logs/", in: StorageContainer(name: "c"))?.absoluteString
                == "https://acct.blob.core.windows.net/c/logs/")
    }
}

// MARK: - Azure delete

@Suite("Azure folder delete")
struct AzureFolderDeleteTests {

    private func client(account: String) -> AzureBlobRESTClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IntegrityStubURLProtocol.self]
        return AzureBlobRESTClient(
            endpoint: AzureStorageEndpoint(account: account),
            tokenSource: StubAzureToken(),
            session: URLSession(configuration: configuration)
        )
    }

    /// On a flat account the folder marker is exactly `logs/`, and nothing else may be
    /// touched — least of all a blob called `logs`.
    @Test("On a flat account only the marker itself is deleted")
    func flatAccount() async throws {
        let account = IntegrityStubURLProtocol.uniqueHost(prefix: "flat")
        try await client(account: account).deleteBlob(container: "c", key: "logs/")
        let paths = IntegrityRecorder.shared.requests(forHost: "\(account).blob.core.windows.net").map(\.path)
        #expect(paths == ["DELETE /c/logs/"])
    }

    /// Verified live: a hierarchical-namespace account answers `400 InvalidUri` for
    /// `dir/`, and the directory is deleted at `dir`.
    @Test("On a Data Lake account the directory is deleted without its slash")
    func hierarchicalAccount() async throws {
        let account = IntegrityStubURLProtocol.uniqueHost(prefix: "hns")
        try await client(account: account).deleteBlob(container: "c", key: "logs/")
        let paths = IntegrityRecorder.shared.requests(forHost: "\(account).blob.core.windows.net").map(\.path)
        #expect(paths == ["DELETE /c/logs/", "DELETE /c/logs"])
    }

    @Test("A plain blob is never retried under another name")
    func plainBlobNotRetried() async throws {
        let account = IntegrityStubURLProtocol.uniqueHost(prefix: "hns")
        await #expect(throws: (any Error).self) {
            try await client(account: account).deleteBlob(container: "c", key: "bad")
        }
        let paths = IntegrityRecorder.shared.requests(forHost: "\(account).blob.core.windows.net").map(\.path)
        #expect(paths == ["DELETE /c/bad"])
    }
}

// MARK: - S3 listing

@Suite("S3 listing keys")
struct S3ListingKeyTests {

    /// Verified live: with `encoding-type=url`, S3 sends a space as `+` and a literal
    /// `+` as `%2B`.
    @Test("URL-encoded keys decode to exactly what was stored")
    func decodesKeys() throws {
        let xml = """
            <ListBucketResult>
              <IsTruncated>false</IsTruncated>
              <Contents><Key>p/sp+ace.txt</Key><Size>1</Size></Contents>
              <Contents><Key>p/plus%2Bsign.txt</Key><Size>1</Size></Contents>
              <Contents><Key>p/trail.txt+</Key><Size>1</Size></Contents>
              <Contents><Key>p/pct%2541.txt</Key><Size>1</Size></Contents>
              <Contents><Key>p/%C3%BC.txt</Key><Size>1</Size></Contents>
              <CommonPrefixes><Prefix>p/my+folder/</Prefix></CommonPrefixes>
            </ListBucketResult>
            """
        let page = try S3ObjectListXMLParser(isURLEncoded: true).parse(Data(xml.utf8))
        #expect(page.objects.map(\.key) == [
            "p/sp ace.txt", "p/plus+sign.txt", "p/trail.txt ", "p/pct%41.txt", "p/ü.txt", "p/my folder/",
        ])
    }

    /// `"report.csv "` and `"report.csv"` are different objects.
    @Test("Keys are never trimmed")
    func keysNotTrimmed() throws {
        let xml = "<ListBucketResult><Contents><Key> lead.txt </Key><Size>1</Size></Contents></ListBucketResult>"
        let page = try S3ObjectListXMLParser().parse(Data(xml.utf8))
        #expect(page.objects.map(\.key) == [" lead.txt "])
    }

    /// A folder delete lists without a delimiter. Dropping the nested `sub/` marker
    /// there left the folder standing after it was "deleted".
    @Test("A full-key listing keeps nested folder markers")
    func keepsMarkersWhenAsked() throws {
        let xml = """
            <ListBucketResult>
              <Contents><Key>logs/sub/</Key><Size>0</Size></Contents>
              <Contents><Key>logs/sub/a.txt</Key><Size>3</Size></Contents>
            </ListBucketResult>
            """
        let browse = try S3ObjectListXMLParser().parse(Data(xml.utf8))
        #expect(browse.objects.map(\.key) == ["logs/sub/a.txt"])
        let full = try S3ObjectListXMLParser(keepsFolderMarkers: true).parse(Data(xml.utf8))
        #expect(full.objects.map(\.key) == ["logs/sub/", "logs/sub/a.txt"])
    }
}

// MARK: - S3 multipart

@Suite("S3 multipart sizing and abort")
struct S3MultipartTests {

    private let mebibyte = 1024 * 1024

    @Test("Small files keep the requested part size")
    func smallFile() {
        #expect(S3RESTClient.effectivePartSize(requested: 8 * mebibyte, fileSize: 100 * Int64(mebibyte)) == 8 * mebibyte)
    }

    @Test("The S3 minimum still applies")
    func minimum() {
        #expect(S3RESTClient.effectivePartSize(requested: mebibyte, fileSize: 10) == 5 * mebibyte)
    }

    /// At 8 MiB parts, anything past ~78 GiB needed part 10,001 and failed at the end.
    @Test("A very large file fits in 10,000 parts")
    func largeFile() {
        let size: Int64 = 100 * 1024 * 1024 * 1024
        let part = S3RESTClient.effectivePartSize(requested: 8 * mebibyte, fileSize: size)
        #expect(part % mebibyte == 0)
        #expect((size + Int64(part) - 1) / Int64(part) <= Int64(S3RESTClient.maximumPartCount))
    }

    /// Stop cancels the upload's task, and URLSession won't start a request from a
    /// cancelled task — so an inline abort never left the machine and the parts kept
    /// billing.
    @Test("Cancelling an upload still aborts it on the server")
    func cancelAborts() async throws {
        let bucket = IntegrityStubURLProtocol.uniqueHost(prefix: "cancel")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IntegrityStubURLProtocol.self]
        let client = S3RESTClient(
            endpoint: S3Endpoint(region: "us-west-2"),
            credentialSource: StubAWSCredentials(),
            session: URLSession(configuration: configuration)
        )
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("strata-\(UUID().uuidString)")
        try Data(repeating: 7, count: 1024).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let upload = Task {
            try await client.putObjectMultipart(bucket: bucket, key: "big.bin", fileURL: file, contentType: nil)
        }
        // The stub holds the part upload open, so wait for it to arrive and then Stop.
        let host = "\(bucket).s3.us-west-2.amazonaws.com"
        for _ in 0..<200 where !IntegrityRecorder.shared.requests(forHost: host).contains(where: { $0.path.hasPrefix("PUT") }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        upload.cancel()
        _ = await upload.result

        let requests = IntegrityRecorder.shared.requests(forHost: host)
        #expect(requests.contains { $0.path == "DELETE /big.bin" && $0.query.contains("uploadId=UPLOAD1") })
    }
}

// MARK: - Downloads

@Suite("Download collisions")
@MainActor
struct DownloadCollisionTests {

    /// A second, separate Download of another `data.csv` has to see the first as taken
    /// even though nothing is on disk yet.
    @Test("Unfinished downloads claim their destination")
    func claimsDestination() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("strata-claim-\(UUID().uuidString).csv")
        let queue = TransferQueue.shared
        queue.enqueueDownload(
            object: StorageObject(key: "data.csv", size: 1),
            container: StorageContainer(name: "c"),
            to: url,
            provider: NeverFinishingProvider()
        )
        #expect(queue.claimedDownloadPaths.contains(url.standardizedFileURL.path))
        if let item = queue.transfers.first(where: { $0.localURL == url }) { queue.cancel(item) }
    }
}

// MARK: - Favorites

@Suite("Favorites survive a bad entry")
@MainActor
struct FavoritesResilienceTests {

    @Test("One unreadable favorite costs only itself, and is kept aside")
    func lossyLoad() throws {
        let name = "com.kizersolutions.strata.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer {
            defaults.removePersistentDomain(forName: name)
            UserDefaults.standard.removeSuite(named: name)
        }
        let good = Favorite(account: .azure("acct"), container: "data", prefix: "raw/")
        var array = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode([good])) as? [Any])
        array.append(["something": "from a newer version"])
        let stored = try JSONSerialization.data(withJSONObject: array)
        defaults.set(stored, forKey: "Favorites")

        let store = FavoritesStore(defaults: defaults)
        #expect(store.favorites.map(\.id) == [good.id])
        #expect(defaults.data(forKey: FavoritesStore.unreadableBackupKey) == stored)
    }
}

// MARK: - Fixtures

private struct StubAzureToken: AzureTokenSource {
    func token(asOf now: Date) async throws -> AzureAccessToken {
        AzureAccessToken(accessToken: "fake", expiresOn: now.addingTimeInterval(3600), tenant: nil, subscription: nil)
    }
}

private struct StubAWSCredentials: AWSCredentialSource {
    func credentials(asOf now: Date) async throws -> AWSCredentials {
        AWSCredentials(accessKeyID: "AKIAEXAMPLE", secretAccessKey: "secret", sessionToken: nil, expiration: nil)
    }
}

/// A provider whose transfers never complete, so a queued download stays unfinished.
private struct NeverFinishingProvider: StorageProvider {
    var kind: ProviderKind { .azureBlob }
    var displayName: String { "never" }
    func listContainers() async throws -> [StorageContainer] { [] }
    func listObjects(in container: StorageContainer, prefix: String) async throws -> [StorageObject] { [] }
    func fetchMetadata(for object: StorageObject, in container: StorageContainer) async throws -> ObjectMetadata {
        throw CancellationError()
    }
    func objectURL(forKey key: String, in container: StorageContainer) -> URL? { nil }
    func upload(from fileURL: URL, toKey key: String, in container: StorageContainer, contentType: String?, plan: UploadPlan, onProgress: (@Sendable (Int64, Int64) -> Void)?) async throws {}
    func download(fromKey key: String, in container: StorageContainer, to destinationURL: URL, onProgress: (@Sendable (Int64, Int64) -> Void)?) async throws {
        try await Task.sleep(for: .seconds(3600))
    }
    func delete(key: String, in container: StorageContainer) async throws {}
    func listAllKeys(under prefix: String, in container: StorageContainer) async throws -> [StorageObject] { [] }
    func deletionRecovery(in container: StorageContainer) async -> DeletionRecovery { .unknown }
}

struct RecordedRequest: Sendable {
    /// `METHOD /percent-encoded/path`, so tests compare exactly what went on the wire.
    let path: String
    let query: String
}

final class IntegrityRecorder: @unchecked Sendable {
    static let shared = IntegrityRecorder()
    private let lock = NSLock()
    private var recorded: [String: [RecordedRequest]] = [:]

    func record(_ request: URLRequest) {
        guard let url = request.url, let host = url.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        lock.lock()
        defer { lock.unlock() }
        recorded[host, default: []].append(RecordedRequest(
            path: "\(request.httpMethod ?? "GET") \(components.percentEncodedPath)",
            query: components.percentEncodedQuery ?? ""
        ))
    }

    func requests(forHost host: String) -> [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded[host] ?? []
    }
}

/// Canned responses, chosen by the host's prefix. Every test uses its own host, so the
/// recorder needs no reset while tests run in parallel.
///
/// - `hns…` Azure accounts refuse a trailing-slash blob name with `400 InvalidUri`,
///   as a real Data Lake account does; `bad` fails outright.
/// - `flat…` Azure accounts accept any name.
/// - `cancel…` S3 buckets start a multipart upload, then hold the part PUT open
///   until the client gives up on it.
final class IntegrityStubURLProtocol: URLProtocol {

    static func uniqueHost(prefix: String) -> String {
        prefix + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        IntegrityRecorder.shared.record(request)
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        let query = url.query(percentEncoded: true) ?? ""
        let method = request.httpMethod ?? "GET"

        let status: Int
        var body = ""
        if host.hasPrefix("hns") {
            if path.hasSuffix("/") {
                status = 400
                body = "<Error><Code>InvalidUri</Code></Error>"
            } else if path.hasSuffix("/bad") {
                status = 403
                body = "<Error><Code>AuthorizationPermissionMismatch</Code></Error>"
            } else {
                status = 202
            }
        } else if host.hasPrefix("flat") {
            status = 202
        } else if host.hasPrefix("cancel") {
            if method == "PUT" { return }   // never answers; the client cancels it
            if method == "POST" && query.contains("uploads") {
                status = 200
                body = "<InitiateMultipartUploadResult><UploadId>UPLOAD1</UploadId></InitiateMultipartUploadResult>"
            } else {
                status = 204
            }
        } else {
            status = 404
        }

        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
