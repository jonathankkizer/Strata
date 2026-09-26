import Testing
import Foundation
@testable import Strata

/// Resuming against the real services: an upload fails part-way for real, carries
/// on, and the object that lands is compared byte for byte with the file. A download
/// is stopped part-way and picked up again. TODO.md R1b.
///
/// The failure is injected by `FlakyProxy`, which passes every request through to the
/// real service except the one it's told to break, once. Skipped unless the live
/// environments are configured (see S3IntegrationTests / AzureDeleteIntegrationTests).
/// Everything is created under `strata-test/` and removed.
@Suite("Resume live integration", .serialized)
struct ResumeIntegrationTests {

    private let mebibyte = 1024 * 1024

    private func randomFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("strata-live-\(UUID().uuidString)")
        // Random, so a part landing in the wrong place can't go unnoticed.
        var generator = SystemRandomNumberGenerator()
        var data = Data(capacity: bytes)
        while data.count < bytes {
            var word = generator.next()
            data.append(contentsOf: withUnsafeBytes(of: &word) { Array($0) }.prefix(bytes - data.count))
        }
        try data.write(to: url)
        return url
    }

    @Test("S3: a multipart upload that fails part-way resumes and lands intact",
          .enabled(if: S3IntegrationEnvironment.isConfigured))
    func s3() async throws {
        let bucket = S3IntegrationEnvironment().bucket
        let key = "strata-test/resume-\(UUID().uuidString).bin"
        let file = try randomFile(bytes: 11 * mebibyte)
        defer { try? FileManager.default.removeItem(at: file) }
        let tag = UUID().uuidString
        FlakyProxy.breakOnce(tag: tag) { $0.httpMethod == "PUT" && ($0.url?.query ?? "").hasPrefix("partNumber=2&") }

        let credentials = AWSCLICredentialProvider()
        let flaky = S3RESTClient(endpoint: S3Endpoint(region: "us-east-1"), credentialSource: credentials,
                                 session: FlakyProxy.session(tag: tag), retryPolicy: RetryPolicy(maxAttempts: 1))
        let direct = S3RESTClient(endpoint: S3Endpoint(region: "us-east-1"), credentialSource: credentials)
        let state = UploadResumeState()
        defer { Task { try? await direct.deleteObject(bucket: bucket, key: key) } }

        await #expect(throws: (any Error).self) {
            try await flaky.putObjectMultipart(bucket: bucket, key: key, fileURL: file, contentType: nil, partSize: 5 * mebibyte, resume: state)
        }
        let uploadID = try #require(state.uploadID)
        #expect(state.etag(forPart: 1) != nil)

        try await flaky.putObjectMultipart(bucket: bucket, key: key, fileURL: file, contentType: nil, partSize: 5 * mebibyte, resume: state)
        #expect(FlakyProxy.partNumbersSent(tag: tag) == [1, 2, 2, 3])
        #expect(FlakyProxy.uploadIDsUsed(tag: tag) == [uploadID])

        let metadata = try await direct.headObject(bucket: bucket, key: key)
        #expect(metadata.etag?.hasSuffix("-3\"") == true)
        let downloaded = FileManager.default.temporaryDirectory.appendingPathComponent("strata-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try await direct.downloadObject(bucket: bucket, key: key, to: downloaded)
        #expect(try Data(contentsOf: downloaded) == Data(contentsOf: file))
    }

    @Test("Azure: a block upload that fails part-way resumes and lands intact",
          .enabled(if: AzureIntegrationEnvironment.isConfigured))
    func azure() async throws {
        let environment = AzureIntegrationEnvironment()
        let key = "strata-test/resume-\(UUID().uuidString).bin"
        let file = try randomFile(bytes: 10 * mebibyte)
        defer { try? FileManager.default.removeItem(at: file) }
        let state = UploadResumeState()
        _ = state.prepare(for: file, chunkSize: 4 * mebibyte)
        let secondBlock = state.blockID(1)
        let tag = UUID().uuidString
        FlakyProxy.breakOnce(tag: tag) { request in
            let query = request.url?.query(percentEncoded: true) ?? ""
            return query.contains("comp=block&") && query.removingPercentEncoding?.contains(secondBlock) == true
        }

        let token = AzureCLITokenProvider()
        let endpoint = AzureStorageEndpoint(account: environment.account)
        let flaky = AzureBlobRESTClient(endpoint: endpoint, tokenSource: token, session: FlakyProxy.session(tag: tag),
                                        retryPolicy: RetryPolicy(maxAttempts: 1))
        let direct = AzureBlobRESTClient(endpoint: endpoint, tokenSource: token)
        defer { Task { try? await direct.deleteBlob(container: environment.container, key: key) } }

        await #expect(throws: (any Error).self) {
            try await flaky.putBlockList(container: environment.container, key: key, fileURL: file, contentType: nil, blockSize: 4 * mebibyte, resume: state)
        }
        #expect(state.hasBlock(0))

        try await flaky.putBlockList(container: environment.container, key: key, fileURL: file, contentType: nil, blockSize: 4 * mebibyte, resume: state)
        #expect(FlakyProxy.blockPutCount(tag: tag) == 4)   // 0, 1 (broken), then 1 and 2

        let downloaded = FileManager.default.temporaryDirectory.appendingPathComponent("strata-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try await direct.downloadBlob(container: environment.container, key: key, to: downloaded)
        #expect(try Data(contentsOf: downloaded) == Data(contentsOf: file))
    }

    @Test("S3: a download stopped part-way picks up where it stopped",
          .enabled(if: S3IntegrationEnvironment.isConfigured))
    func s3Download() async throws {
        let bucket = S3IntegrationEnvironment().bucket
        let key = "strata-test/resume-download-\(UUID().uuidString).bin"
        let file = try randomFile(bytes: 24 * mebibyte)
        defer { try? FileManager.default.removeItem(at: file) }
        let client = S3RESTClient(endpoint: S3Endpoint(region: "us-east-1"), credentialSource: AWSCLICredentialProvider())
        try await client.putObjectMultipart(bucket: bucket, key: key, fileURL: file, contentType: nil)
        defer { Task { try? await client.deleteObject(bucket: bucket, key: key) } }

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("strata-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let resume = DownloadResumeState()
        let progress = ProgressRecorder()
        let first = Task {
            try await client.downloadObject(bucket: bucket, key: key, to: destination, resume: resume) { sent, _ in
                progress.record(sent)
            }
        }
        for _ in 0..<500 where (progress.last ?? 0) < Int64(4 * mebibyte) {
            try await Task.sleep(for: .milliseconds(10))
        }
        first.cancel()
        _ = await first.result
        for _ in 0..<200 where resume.resumeData == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(resume.resumeData != nil)

        let resumedProgress = ProgressRecorder()
        try await client.downloadObject(bucket: bucket, key: key, to: destination, resume: resume) { sent, _ in
            resumedProgress.record(sent)
        }
        // Carried on from somewhere past the start, not from zero.
        #expect((resumedProgress.first ?? 0) > Int64(mebibyte))
        #expect(try Data(contentsOf: destination) == Data(contentsOf: file))
    }
}

/// Passes requests through to the real network, except the one a test has marked to
/// break, which fails once with a dropped connection. Keyed by a tag carried in the
/// session configuration, so tests don't see each other's traffic.
final class FlakyProxy: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var predicates: [String: @Sendable (URLRequest) -> Bool] = [:]
    nonisolated(unsafe) private static var broken = Set<String>()
    nonisolated(unsafe) private static var seen: [String: [URLRequest]] = [:]
    private static let tagHeader = "X-Strata-Test-Tag"

    private var inner: URLSessionTask?

    static func breakOnce(tag: String, when predicate: @escaping @Sendable (URLRequest) -> Bool) {
        lock.withLock { predicates[tag] = predicate }
    }

    static func session(tag: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlakyProxy.self]
        configuration.httpAdditionalHeaders = [tagHeader: tag]
        return URLSession(configuration: configuration)
    }

    static func partNumbersSent(tag: String) -> [Int] {
        lock.withLock { seen[tag] ?? [] }.compactMap { request in
            request.url?.query?.split(separator: "&").first { $0.hasPrefix("partNumber=") }
                .flatMap { Int($0.dropFirst("partNumber=".count)) }
        }
    }

    static func uploadIDsUsed(tag: String) -> Set<String> {
        Set(lock.withLock { seen[tag] ?? [] }.compactMap { request in
            request.url?.query(percentEncoded: true)?.split(separator: "&").first { $0.hasPrefix("uploadId=") }
                .map { String($0.dropFirst("uploadId=".count)).removingPercentEncoding ?? "" }
        })
    }

    static func blockPutCount(tag: String) -> Int {
        lock.withLock { seen[tag] ?? [] }.filter { ($0.url?.query(percentEncoded: true) ?? "").contains("comp=block&") }.count
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: tagHeader) != nil && URLProtocol.property(forKey: "FlakyProxyHandled", in: request) == nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let tag = request.value(forHTTPHeaderField: Self.tagHeader) else { return }
        var outgoing = request
        outgoing.setValue(nil, forHTTPHeaderField: Self.tagHeader)
        let body = Self.readBody(of: request)
        outgoing.httpBodyStream = nil

        let shouldBreak = Self.lock.withLock { () -> Bool in
            Self.seen[tag, default: []].append(request)
            guard let predicate = Self.predicates[tag], !Self.broken.contains(tag), predicate(request) else { return false }
            Self.broken.insert(tag)
            return true
        }
        if shouldBreak {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }

        let handle: @Sendable (Data?, URLResponse?, (any Error)?) -> Void = { [weak self] data, response, error in
            guard let self else { return }
            if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
            if let response { self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            if let data { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        let task = body.isEmpty && request.httpMethod != "PUT" && request.httpMethod != "POST"
            ? URLSession.shared.dataTask(with: outgoing, completionHandler: handle)
            : URLSession.shared.uploadTask(with: outgoing, from: body, completionHandler: handle)
        inner = task
        task.resume()
    }

    override func stopLoading() {
        inner?.cancel()
    }

    private static func readBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
