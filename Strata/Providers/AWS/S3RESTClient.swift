import Foundation

enum S3Error: Error, Sendable {
    case notHTTPResponse
    case malformedResponse
    case httpError(status: Int, code: String?, message: String?)
    /// The bucket lives in another region. Carries the right one when S3 tells us,
    /// so the caller can retry rather than just fail.
    case wrongRegion(bucket: String, correctRegion: String?)
    case noSuchBucket(String)
}

/// Reports upload byte progress. `didSendBodyData` is a *task*-delegate method and does
/// work on a shared session, unlike the download side — see `DownloadSession` for why
/// downloads need their own session.
private final class S3UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let baseOffset: Int64
    private let totalBytes: Int64
    private let onProgress: @Sendable (Int64, Int64) -> Void

    init(baseOffset: Int64, totalBytes: Int64, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.baseOffset = baseOffset
        self.totalBytes = totalBytes
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onProgress(baseOffset + totalBytesSent, totalBytes)
    }
}

/// The S3 data-plane operations Strata needs, over SigV4-signed REST.
///
/// Deliberately the same shape as `AzureBlobRESTClient`: a `perform` that signs,
/// sends, and maps status codes; XML parsing via Foundation; downloads through the
/// shared `DownloadSession` so byte progress works; uploads streamed from disk so
/// memory stays bounded regardless of object size.
struct S3RESTClient: Sendable {

    let endpoint: S3Endpoint
    let credentialSource: any AWSCredentialSource
    let session: URLSession
    let downloader: DownloadSession

    private var signer: SigV4Signer { SigV4Signer(region: endpoint.region, service: "s3") }

    init(
        endpoint: S3Endpoint,
        credentialSource: any AWSCredentialSource,
        session: URLSession = .shared,
        downloader: DownloadSession = .shared
    ) {
        self.endpoint = endpoint
        self.credentialSource = credentialSource
        self.session = session
        self.downloader = downloader
    }

    // MARK: - Reads

    func listBuckets() async throws -> [StorageContainer] {
        let data = try await perform(method: "GET", url: endpoint.serviceURL, payload: .empty).data
        return try S3BucketListXMLParser().parse(data)
    }

    /// One page of a listing. `delimiter` of "/" produces `CommonPrefixes`, which is
    /// what makes S3's flat keyspace browsable as folders.
    func listObjectsPage(
        bucket: String,
        prefix: String,
        delimiter: String? = "/",
        continuationToken: String? = nil,
        maxKeys: Int = 1000
    ) async throws -> S3ObjectPage {
        guard var components = URLComponents(url: endpoint.bucketURL(bucket), resolvingAgainstBaseURL: false) else {
            throw S3Error.malformedResponse
        }
        var query: [(name: String, value: String)] = [
            ("list-type", "2"),
            ("max-keys", String(maxKeys)),
        ]
        if !prefix.isEmpty { query.append(("prefix", prefix)) }
        if let delimiter { query.append(("delimiter", delimiter)) }
        if let continuationToken {
            query.append(("continuation-token", continuationToken))
        }
        // `percentEncodedQuery` with our own encoder, never `queryItems` — see
        // `SigV4Signer.canonicalQueryString`. URLComponents' encoding is too permissive
        // for SigV4 and every listing would 403.
        components.percentEncodedQuery = SigV4Signer.canonicalQueryString(query)
        guard let url = components.url else { throw S3Error.malformedResponse }

        let data = try await perform(method: "GET", url: url, payload: .empty, bucket: bucket).data
        return try S3ObjectListXMLParser().parse(data)
    }

    /// Every page of a listing. S3 caps a response at 1000 keys, so a folder with more
    /// than that would silently appear truncated without this.
    ///
    /// `maxKeys` is exposed mainly so tests can force real paging against a handful of
    /// objects rather than having to create a thousand.
    func listAllObjects(
        bucket: String,
        prefix: String,
        delimiter: String? = "/",
        maxKeys: Int = 1000
    ) async throws -> [StorageObject] {
        var all: [StorageObject] = []
        var token: String?
        repeat {
            let page = try await listObjectsPage(
                bucket: bucket,
                prefix: prefix,
                delimiter: delimiter,
                continuationToken: token,
                maxKeys: maxKeys
            )
            all.append(contentsOf: page.objects)
            token = page.isTruncated ? page.continuationToken : nil
            // Defensive: a truncated page with no token would otherwise spin forever.
            if page.isTruncated && page.continuationToken == nil { break }
        } while token != nil
        return all
    }

    func headObject(bucket: String, key: String) async throws -> ObjectMetadata {
        guard let url = endpoint.objectURL(bucket: bucket, key: key) else {
            throw S3Error.malformedResponse
        }
        let response = try await perform(method: "HEAD", url: url, payload: .empty, bucket: bucket).response
        return Self.metadata(from: response)
    }

    /// Streams an object to disk with byte progress. Uses `DownloadSession` for the
    /// same reason Azure does — the async convenience API never calls the download
    /// delegate, so progress would be invisible.
    func downloadObject(
        bucket: String,
        key: String,
        to destinationURL: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
        guard let url = endpoint.objectURL(bucket: bucket, key: key) else {
            throw S3Error.malformedResponse
        }
        let request = try await signedRequest(method: "GET", url: url, payload: .empty)
        let (temporaryURL, http) = try await downloader.download(request, onProgress: onProgress)

        var consumed = false
        defer { if !consumed { try? FileManager.default.removeItem(at: temporaryURL) } }

        guard (200..<300).contains(http.statusCode) else {
            // A failed GET still writes S3's error XML to the temp file.
            let body = (try? String(contentsOf: temporaryURL, encoding: .utf8)) ?? ""
            throw Self.error(
                status: http.statusCode,
                body: body,
                bucket: bucket,
                response: http,
                signedRegion: endpoint.region
            )
        }

        let manager = FileManager.default
        if manager.fileExists(atPath: destinationURL.path) {
            _ = try manager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try manager.moveItem(at: temporaryURL, to: destinationURL)
        }
        consumed = true
    }

    /// The region a bucket actually lives in. S3 returns an empty
    /// `LocationConstraint` for us-east-1 and, confusingly, `EU` for eu-west-1.
    func bucketRegion(bucket: String) async throws -> String {
        guard var components = URLComponents(url: endpoint.bucketURL(bucket), resolvingAgainstBaseURL: false) else {
            throw S3Error.malformedResponse
        }
        components.percentEncodedQuery = "location="
        guard let url = components.url else { throw S3Error.malformedResponse }

        let (data, response) = try await perform(method: "GET", url: url, payload: .empty, bucket: bucket)
        if let header = response.value(forHTTPHeaderField: "x-amz-bucket-region"), !header.isEmpty {
            return header
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        guard let constraint = S3ErrorXMLParser.element("LocationConstraint", in: body) else {
            return "us-east-1"
        }
        return constraint == "EU" ? "eu-west-1" : constraint
    }

    /// Removes an object. S3 answers 204 whether or not the key existed, so this is
    /// idempotent by nature — which is what makes it safe for test teardown.
    func deleteObject(bucket: String, key: String) async throws {
        guard let url = endpoint.objectURL(bucket: bucket, key: key) else {
            throw S3Error.malformedResponse
        }
        _ = try await perform(method: "DELETE", url: url, payload: .empty, bucket: bucket)
    }

    /// Whether the bucket keeps previous versions, which is what decides if a delete
    /// here can be undone. `Status` is absent on a bucket that has never had versioning
    /// turned on, and `Suspended` on one where it was turned back off — in both cases a
    /// delete is final for anything written since.
    func bucketVersioningEnabled(bucket: String) async throws -> Bool {
        guard var components = URLComponents(url: endpoint.bucketURL(bucket), resolvingAgainstBaseURL: false) else {
            throw S3Error.malformedResponse
        }
        components.percentEncodedQuery = "versioning="
        guard let url = components.url else { throw S3Error.malformedResponse }

        let data = try await perform(method: "GET", url: url, payload: .empty, bucket: bucket).data
        let body = String(data: data, encoding: .utf8) ?? ""
        return S3ErrorXMLParser.element("Status", in: body) == "Enabled"
    }

    // MARK: - Writes

    /// Single-request upload, streamed from disk. Emits `s3:ObjectCreated:Put`.
    func putObject(
        bucket: String,
        key: String,
        fileURL: URL,
        contentType: String?,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
        guard let url = endpoint.objectURL(bucket: bucket, key: key) else {
            throw S3Error.malformedResponse
        }
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }

        let total = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let delegate = onProgress.map {
            S3UploadProgressDelegate(baseOffset: 0, totalBytes: total, onProgress: $0)
        }
        // Hashing the file up front would mean reading it twice; UNSIGNED-PAYLOAD is
        // S3's sanctioned answer for a streamed body over HTTPS.
        _ = try await perform(
            method: "PUT",
            url: url,
            payload: .unsigned,
            bucket: bucket,
            body: .file(fileURL),
            extraHeaders: headers,
            delegate: delegate
        )
    }

    /// Multipart upload, streamed part by part. Emits
    /// `s3:ObjectCreated:CompleteMultipartUpload`.
    ///
    /// An abandoned multipart upload keeps billing for its stored parts, so a failure
    /// after initiation aborts rather than leaking them.
    /// S3 rejects any part but the last below 5 MiB with `EntityTooSmall`, so a caller
    /// deriving a part size from a configurable threshold can't be trusted to stay
    /// above it. Clamped rather than rejected: a smaller threshold is a legitimate
    /// request about *when* to go multipart, not about how to chunk it.
    static let minimumPartSize = 5 * 1024 * 1024

    func putObjectMultipart(
        bucket: String,
        key: String,
        fileURL: URL,
        contentType: String?,
        partSize: Int = 8 * 1024 * 1024,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
        let partSize = max(partSize, Self.minimumPartSize)
        let total = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let uploadID = try await createMultipartUpload(bucket: bucket, key: key, contentType: contentType)

        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }

            var parts: [(number: Int, etag: String)] = []
            var partNumber = 1
            var offset: Int64 = 0

            while true {
                let chunk = try handle.read(upToCount: partSize) ?? Data()
                if chunk.isEmpty { break }
                let etag = try await uploadPart(
                    bucket: bucket,
                    key: key,
                    uploadID: uploadID,
                    partNumber: partNumber,
                    body: chunk,
                    baseOffset: offset,
                    totalBytes: total,
                    onProgress: onProgress
                )
                parts.append((partNumber, etag))
                offset += Int64(chunk.count)
                partNumber += 1
            }

            // S3 rejects a completion with zero parts, so an empty file goes up as a
            // plain PutObject instead.
            guard !parts.isEmpty else {
                try await abortMultipartUpload(bucket: bucket, key: key, uploadID: uploadID)
                try await putObject(bucket: bucket, key: key, fileURL: fileURL, contentType: contentType, onProgress: onProgress)
                return
            }
            try await completeMultipartUpload(bucket: bucket, key: key, uploadID: uploadID, parts: parts)
        } catch {
            try? await abortMultipartUpload(bucket: bucket, key: key, uploadID: uploadID)
            throw error
        }
    }

    func createMultipartUpload(bucket: String, key: String, contentType: String?) async throws -> String {
        guard let url = multipartURL(bucket: bucket, key: key, query: "uploads=") else {
            throw S3Error.malformedResponse
        }
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }

        let data = try await perform(
            method: "POST",
            url: url,
            payload: .empty,
            bucket: bucket,
            extraHeaders: headers
        ).data
        guard let uploadID = S3ErrorXMLParser.element("UploadId", in: String(data: data, encoding: .utf8) ?? "") else {
            throw S3Error.malformedResponse
        }
        return uploadID
    }

    private func uploadPart(
        bucket: String,
        key: String,
        uploadID: String,
        partNumber: Int,
        body: Data,
        baseOffset: Int64,
        totalBytes: Int64,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> String {
        guard let url = multipartURL(
            bucket: bucket,
            key: key,
            query: "partNumber=\(partNumber)&uploadId=\(SigV4Signer.encodePathSegment(uploadID))"
        ) else {
            throw S3Error.malformedResponse
        }
        let delegate = onProgress.map {
            S3UploadProgressDelegate(baseOffset: baseOffset, totalBytes: totalBytes, onProgress: $0)
        }
        // The part is already in memory, so it can be hashed properly rather than
        // sent unsigned.
        let response = try await perform(
            method: "PUT",
            url: url,
            payload: .data(body),
            bucket: bucket,
            body: .data(body),
            delegate: delegate
        ).response

        guard let etag = response.value(forHTTPHeaderField: "ETag") else {
            throw S3Error.malformedResponse
        }
        return etag
    }

    func completeMultipartUpload(
        bucket: String,
        key: String,
        uploadID: String,
        parts: [(number: Int, etag: String)]
    ) async throws {
        guard let url = multipartURL(
            bucket: bucket,
            key: key,
            query: "uploadId=\(SigV4Signer.encodePathSegment(uploadID))"
        ) else {
            throw S3Error.malformedResponse
        }
        let body = Data(Self.completionXML(parts: parts).utf8)
        _ = try await perform(
            method: "POST",
            url: url,
            payload: .data(body),
            bucket: bucket,
            body: .data(body),
            extraHeaders: ["Content-Type": "application/xml"]
        )
    }

    func abortMultipartUpload(bucket: String, key: String, uploadID: String) async throws {
        guard let url = multipartURL(
            bucket: bucket,
            key: key,
            query: "uploadId=\(SigV4Signer.encodePathSegment(uploadID))"
        ) else {
            throw S3Error.malformedResponse
        }
        _ = try await perform(method: "DELETE", url: url, payload: .empty, bucket: bucket)
    }

    /// The completion body must list parts in ascending order with their ETags exactly
    /// as returned — quotes included. The ETag is server-supplied text landing inside
    /// XML, so its metacharacters are escaped; real ETags (hex, quotes, `-N` multipart
    /// suffixes) pass through byte-for-byte.
    static func completionXML(parts: [(number: Int, etag: String)]) -> String {
        let entries = parts.sorted { $0.number < $1.number }.map { part in
            let quoted = part.etag.hasPrefix("\"") ? part.etag : "\"\(part.etag)\""
            let escaped = quoted
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return "<Part><PartNumber>\(part.number)</PartNumber><ETag>\(escaped)</ETag></Part>"
        }.joined()
        return "<CompleteMultipartUpload>\(entries)</CompleteMultipartUpload>"
    }

    // MARK: - Plumbing

    private func multipartURL(bucket: String, key: String, query: String) -> URL? {
        guard let base = endpoint.objectURL(bucket: bucket, key: key),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.percentEncodedQuery = query
        return components.url
    }

    private enum RequestBody {
        case data(Data)
        case file(URL)
    }

    private func signedRequest(
        method: String,
        url: URL,
        payload: SigV4Signer.Payload,
        extraHeaders: [String: String] = [:]
    ) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let credentials = try await credentialSource.credentials(asOf: Date())
        return signer.sign(request, payload: payload, credentials: credentials, date: Date())
    }

    @discardableResult
    private func perform(
        method: String,
        url: URL,
        payload: SigV4Signer.Payload,
        bucket: String? = nil,
        body: RequestBody? = nil,
        extraHeaders: [String: String] = [:],
        delegate: (any URLSessionTaskDelegate)? = nil
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let request = try await signedRequest(method: method, url: url, payload: payload, extraHeaders: extraHeaders)

        let data: Data
        let response: URLResponse
        switch body {
        case .data(let bodyData):
            (data, response) = try await session.upload(for: request, from: bodyData, delegate: delegate)
        case .file(let fileURL):
            (data, response) = try await session.upload(for: request, fromFile: fileURL, delegate: delegate)
        case nil:
            (data, response) = try await session.data(for: request)
        }

        guard let http = response as? HTTPURLResponse else {
            throw S3Error.notHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "",
                bucket: bucket,
                response: http,
                signedRegion: endpoint.region
            )
        }
        return (data, http)
    }

    /// Maps S3's status codes and error codes onto errors the UI can say something
    /// useful about. A 301/307 with a region header is the wrong-region case, which is
    /// recoverable by retrying elsewhere rather than a flat failure.
    static func error(
        status: Int,
        body: String,
        bucket: String?,
        response: HTTPURLResponse,
        signedRegion: String
    ) -> any Error {
        let code = S3ErrorXMLParser.code(in: body)
        let region = response.value(forHTTPHeaderField: "x-amz-bucket-region")

        // A mismatched `x-amz-bucket-region` means the wrong region, whatever status
        // came with it — checked first because real S3 does not answer a cross-region
        // request the way the documentation's redirect examples suggest. Measured
        // against live S3: a eu-west-1 bucket addressed as us-east-1 comes back **403
        // with this header**, not a 301. Mapping that on status alone reported it as a
        // permissions problem and sent you to IAM for a routing issue. This is also
        // what the AWS SDKs key off to retry.
        if let region, !region.isEmpty, region != signedRegion {
            return S3Error.wrongRegion(bucket: bucket ?? "", correctRegion: region)
        }

        // Error *code* is matched before bare status, deliberately. S3 answers 403 for
        // both "you may not do this" and "your signature is wrong", and collapsing them
        // sends you hunting through IAM policies for what is actually a client bug.
        // That misdiagnosis briefly masked a real signing defect during live testing.
        switch code {
        case "PermanentRedirect", "AuthorizationHeaderMalformed":
            return S3Error.wrongRegion(bucket: bucket ?? "", correctRegion: region)
        case "SignatureDoesNotMatch", "InvalidAccessKeyId", "ExpiredToken", "InvalidToken", "TokenRefreshRequired":
            return StorageProviderError.unauthorized
        case "AccessDenied":
            return StorageProviderError.dataPlaneForbidden(account: bucket ?? "")
        case "NoSuchBucket":
            return S3Error.noSuchBucket(bucket ?? "")
        default:
            break
        }

        switch status {
        case 301, 307:
            return S3Error.wrongRegion(bucket: bucket ?? "", correctRegion: region)
        case 401:
            return StorageProviderError.unauthorized
        case 403:
            return StorageProviderError.dataPlaneForbidden(account: bucket ?? "")
        default:
            return S3Error.httpError(status: status, code: code, message: S3ErrorXMLParser.message(in: body))
        }
    }

    /// Decodes the headers a HEAD returns. `x-amz-meta-*` is S3's user-metadata
    /// spelling, the counterpart of Azure's `x-ms-meta-*`.
    static func metadata(from response: HTTPURLResponse) -> ObjectMetadata {
        var custom: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            let lowered = name.lowercased()
            guard lowered.hasPrefix("x-amz-meta-") else { continue }
            custom[String(lowered.dropFirst("x-amz-meta-".count))] = value
        }

        return ObjectMetadata(
            size: response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) ?? 0,
            contentType: response.value(forHTTPHeaderField: "Content-Type"),
            // S3 omits the header entirely for STANDARD, which is the common case.
            storageClass: response.value(forHTTPHeaderField: "x-amz-storage-class") ?? "STANDARD",
            etag: response.value(forHTTPHeaderField: "ETag"),
            lastModified: response.value(forHTTPHeaderField: "Last-Modified").flatMap(Self.parseHTTPDate),
            // S3 has one object type; the field exists for Azure's block/append/page.
            blobType: nil,
            custom: custom
        )
    }

    /// RFC 7231 date, as sent in `Last-Modified`. Fixed locale and zone — a formatter
    /// that picked up the host's would fail to parse on a non-English system.
    static func parseHTTPDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}
