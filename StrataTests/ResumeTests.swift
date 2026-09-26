import Testing
import Foundation
@testable import Strata

/// TODO.md R1b: Retry carries on from where a failed transfer got to.
@Suite("Resuming uploads", .serialized)
struct ResumeTests {

    private let noRetries = RetryPolicy(maxAttempts: 1)

    private func file(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("strata-resume-\(UUID().uuidString)")
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    // MARK: - State

    @Test("A changed file or chunk size throws the record away")
    func fingerprint() throws {
        let url = try file(bytes: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = UploadResumeState()
        #expect(state.prepare(for: url, chunkSize: 4) == false)
        state.recordBlock(0)
        #expect(state.prepare(for: url, chunkSize: 4) == true)
        #expect(state.prepare(for: url, chunkSize: 8) == false)
        #expect(!state.hasBlock(0))

        state.recordBlock(0)
        _ = state.prepare(for: url, chunkSize: 8)
        try Data("different".utf8).write(to: url)
        #expect(state.prepare(for: url, chunkSize: 8) == false)
    }

    @Test("Block IDs are the same length and carry a per-upload tag")
    func blockIDs() {
        let a = UploadResumeState(), b = UploadResumeState()
        #expect(a.blockID(0).count == a.blockID(12345).count)
        #expect(a.blockID(0) != b.blockID(0))
    }

    // MARK: - Azure

    private func azureClient(_ account: String) -> AzureBlobRESTClient {
        AzureBlobRESTClient(
            endpoint: AzureStorageEndpoint(account: account),
            tokenSource: ResumeToken(),
            session: ResumeStub.session(),
            retryPolicy: noRetries
        )
    }

    @Test("Azure: a retry sends only the blocks that didn't make it")
    func azureResume() async throws {
        let account = ResumeStub.host("azfail2")   // the third block (index 2) fails once
        let url = try file(bytes: 12)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = UploadResumeState()
        let client = azureClient(account)
        let host = "\(account).blob.core.windows.net"

        await #expect(throws: (any Error).self) {
            try await client.putBlockList(container: "c", key: "k", fileURL: url, contentType: nil, blockSize: 4, resume: state)
        }
        let firstBlocks = ResumeStub.requests(host).filter { $0.query.contains("comp=block&") }
        #expect(firstBlocks.count == 3)

        try await client.putBlockList(container: "c", key: "k", fileURL: url, contentType: nil, blockSize: 4, resume: state)
        let all = ResumeStub.requests(host)
        let blockPuts = all.filter { $0.query.contains("comp=block&") }
        #expect(blockPuts.count == 4)   // three, then only the one that failed
        let commit = try #require(all.last { $0.query == "comp=blocklist" })
        // The commit names all three blocks, with the IDs the first attempt used.
        let ids = firstBlocks.compactMap { $0.blockID }
        #expect(ids.allSatisfy { commit.body.contains($0) })
    }

    /// The file's size used to be read through `URL`'s resource cache, so a file that
    /// grew between attempts looked unchanged and its tail was never sent.
    @Test("Azure: a file that changed between attempts is sent again in full")
    func azureFileChanged() async throws {
        let account = ResumeStub.host("azfail2")
        let url = try file(bytes: 12)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = UploadResumeState()
        let client = azureClient(account)
        _ = try? await client.putBlockList(container: "c", key: "k", fileURL: url, contentType: nil, blockSize: 4, resume: state)

        try await Task.sleep(for: .milliseconds(1100))   // a visibly newer modification date
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1, 2, 3, 4]))
        try handle.close()

        try await client.putBlockList(container: "c", key: "k", fileURL: url, contentType: nil, blockSize: 4, resume: state)
        let requests = ResumeStub.requests("\(account).blob.core.windows.net")
        let secondAttempt = requests.dropFirst(3)
        #expect(secondAttempt.filter { $0.query.contains("comp=block&") }.count == 4)
        let commit = try #require(requests.last)
        #expect(commit.body.components(separatedBy: "<Latest>").count - 1 == 4)
    }

    @Test("Azure: blocks the service has lost mean starting again, once")
    func azureLostBlocks() async throws {
        let account = ResumeStub.host("azlost")   // first commit after a resume says InvalidBlockList
        let url = try file(bytes: 8)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = UploadResumeState()
        _ = state.prepare(for: url, chunkSize: 4)
        state.recordBlock(0)
        let firstTag = state.blockID(0)

        try await azureClient(account).putBlockList(container: "c", key: "k", fileURL: url, contentType: nil, blockSize: 4, resume: state)
        let puts = ResumeStub.requests("\(account).blob.core.windows.net").filter { $0.query.contains("comp=block&") }
        // One block on the resumed try (block 0 was skipped), then both from scratch
        // under a new tag.
        #expect(puts.count == 3)
        #expect(!puts.suffix(2).contains { $0.blockID == firstTag })
    }

    // MARK: - S3

    private func s3Client() -> S3RESTClient {
        S3RESTClient(
            endpoint: S3Endpoint(region: "us-west-2"),
            credentialSource: ResumeCredentials(),
            session: ResumeStub.session(),
            retryPolicy: noRetries
        )
    }

    private let mebibyte = 1024 * 1024

    @Test("S3: a retry reuses the upload and skips the parts S3 has")
    func s3Resume() async throws {
        let bucket = ResumeStub.host("s3fail2")   // part 2 fails once
        let url = try file(bytes: 11 * mebibyte)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = UploadResumeState()
        let host = "\(bucket).s3.us-west-2.amazonaws.com"

        await #expect(throws: (any Error).self) {
            try await s3Client().putObjectMultipart(bucket: bucket, key: "big", fileURL: url, contentType: nil, partSize: 5 * mebibyte, resume: state)
        }
        // A failure with somewhere to come back to leaves the upload open.
        #expect(!ResumeStub.requests(host).contains { $0.method == "DELETE" })
        #expect(state.uploadID == "UP1")

        try await s3Client().putObjectMultipart(bucket: bucket, key: "big", fileURL: url, contentType: nil, partSize: 5 * mebibyte, resume: state)
        let requests = ResumeStub.requests(host)
        #expect(requests.filter { $0.query.hasPrefix("uploads") }.count == 1)
        let partNumbers = requests.filter { $0.method == "PUT" }.compactMap(\.partNumber)
        #expect(partNumbers == [1, 2, 2, 3])
        let complete = try #require(requests.last { $0.method == "POST" })
        #expect(complete.body.contains("<PartNumber>1</PartNumber>") && complete.body.contains("<PartNumber>3</PartNumber>"))
        #expect(state.uploadID == nil)
    }

    @Test("S3: an upload S3 has forgotten is started again")
    func s3Forgotten() async throws {
        let bucket = ResumeStub.host("s3gone")   // UP-OLD is unknown
        let url = try file(bytes: 6 * mebibyte)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = UploadResumeState()
        _ = state.prepare(for: url, chunkSize: 5 * mebibyte)
        state.uploadID = "UP-OLD"
        state.recordPart(1, etag: "\"e1\"")

        try await s3Client().putObjectMultipart(bucket: bucket, key: "big", fileURL: url, contentType: nil, partSize: 5 * mebibyte, resume: state)
        let requests = ResumeStub.requests("\(bucket).s3.us-west-2.amazonaws.com")
        #expect(requests.filter { $0.query.hasPrefix("uploads") }.count == 1)
        #expect(requests.filter { $0.method == "PUT" }.compactMap(\.partNumber) == [2, 1, 2])
    }

    @Test("S3: abandoning a failed upload aborts it")
    func s3Abandon() async throws {
        let bucket = ResumeStub.host("s3ok")
        let provider = S3Provider(profile: "p", region: "us-west-2", credentialSource: ResumeCredentials(), session: ResumeStub.session())
        let state = UploadResumeState()
        state.uploadID = "UP9"
        await provider.abandonUpload(state, key: "big", in: StorageContainer(name: bucket))
        let requests = ResumeStub.requests("\(bucket).s3.us-west-2.amazonaws.com")
        #expect(requests.contains { $0.method == "DELETE" && $0.query.contains("uploadId=UP9") })
        #expect(state.uploadID == nil)
    }
}

// MARK: - Fixtures

private struct ResumeToken: AzureTokenSource {
    func token(asOf now: Date) async throws -> AzureAccessToken {
        AzureAccessToken(accessToken: "t", expiresOn: now.addingTimeInterval(3600), tenant: nil, subscription: nil)
    }
}

private struct ResumeCredentials: AWSCredentialSource {
    func credentials(asOf now: Date) async throws -> AWSCredentials {
        AWSCredentials(accessKeyID: "AKIA", secretAccessKey: "s", sessionToken: nil, expiration: nil)
    }
}

struct ResumeRequest: Sendable {
    let method: String
    let query: String
    let body: String

    var blockID: String? {
        query.split(separator: "&").first { $0.hasPrefix("blockid=") }
            .map { String($0.dropFirst("blockid=".count)).removingPercentEncoding ?? "" }
    }

    var partNumber: Int? {
        query.split(separator: "&").first { $0.hasPrefix("partNumber=") }.flatMap { Int($0.dropFirst("partNumber=".count)) }
    }
}

/// A stateful stand-in for both services, keyed by host prefix:
/// - `azfail2…`: the block with index 2 fails the first time.
/// - `azlost…`: the first block-list commit answers InvalidBlockList.
/// - `s3fail2…`: part 2 fails the first time.
/// - `s3gone…`: parts for upload `UP-OLD` answer NoSuchUpload.
/// Everything else succeeds. New multipart uploads get ID `UP1`.
final class ResumeStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [String: [ResumeRequest]] = [:]
    nonisolated(unsafe) private static var failedOnce = Set<String>()

    static func host(_ prefix: String) -> String {
        prefix + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(10)
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResumeStub.self]
        return URLSession(configuration: configuration)
    }

    static func requests(_ host: String) -> [ResumeRequest] {
        lock.withLock { log[host] ?? [] }
    }

    /// True the first time it's asked about `key`.
    private static func firstTime(_ key: String) -> Bool {
        lock.withLock { failedOnce.insert(key).inserted }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private func bodyData() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let method = request.httpMethod ?? "GET"
        let query = url.query(percentEncoded: true) ?? ""
        let body = bodyData()
        let entry = ResumeRequest(method: method, query: query, body: String(data: body, encoding: .utf8) ?? "")
        Self.lock.withLock { Self.log[host, default: []].append(entry) }

        var status = 200
        var headers: [String: String] = [:]
        var responseBody = ""

        if host.hasPrefix("azfail2"), let id = entry.blockID,
           let decoded = Data(base64Encoded: id).flatMap({ String(data: $0, encoding: .utf8) }),
           decoded.hasSuffix("-00000002"), Self.firstTime(host + "b2") {
            status = 500
        } else if host.hasPrefix("azlost"), query == "comp=blocklist", Self.firstTime(host + "commit") {
            status = 400
            responseBody = "<Error><Code>InvalidBlockList</Code></Error>"
        } else if host.hasPrefix("az") {
            status = 201
        } else if method == "POST", query.hasPrefix("uploads") {
            responseBody = "<InitiateMultipartUploadResult><UploadId>UP1</UploadId></InitiateMultipartUploadResult>"
        } else if method == "PUT", let part = entry.partNumber {
            if host.hasPrefix("s3gone"), query.contains("uploadId=UP-OLD") {
                status = 404
                responseBody = "<Error><Code>NoSuchUpload</Code></Error>"
            } else if host.hasPrefix("s3fail2"), part == 2, Self.firstTime(host + "p2") {
                status = 500
            } else {
                headers["ETag"] = "\"etag\(part)\""
            }
        } else if method == "DELETE" {
            status = 204
        }

        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
