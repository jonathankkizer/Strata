import Foundation

/// The blob service endpoint for a storage account. The suffix is configurable so
/// sovereign clouds (`blob.core.usgovcloudapi.net`, etc.) drop in later without
/// touching call sites.
struct AzureStorageEndpoint: Sendable, Hashable {
    var account: String
    var blobSuffix: String

    init(account: String, blobSuffix: String = "blob.core.windows.net") {
        self.account = account
        self.blobSuffix = blobSuffix
    }

    /// Azure's actual naming rule: 3–24 lowercase ASCII letters and digits. This is
    /// a security boundary, not just tidiness — `baseURL` interpolates the name into
    /// host position, so a name containing `/` or other URL metacharacters would
    /// redirect requests (and the Bearer token on them) to a different host. Every
    /// path that accepts an account name (typed, favorited, dragged, restored) must
    /// pass this before an endpoint is built — the S3 side's `isDNSCompatible`, for
    /// the same reason.
    static func isValidAccountName(_ name: String) -> Bool {
        (3...24).contains(name.count) && name.allSatisfy { character in
            character.isASCII && (character.isNumber || (character.isLetter && character.isLowercase))
        }
    }

    /// Only meaningful for a valid account name; see `isValidAccountName`.
    var baseURL: URL {
        URL(string: "https://\(account).\(blobSuffix)")!
    }

    /// The URL for the account, a container, or a blob, with the key addressed
    /// exactly: `logs/` and `logs` are different blobs on a flat account, and so are
    /// `a//b` and `a/b`. The query is strictly encoded too, because Azure reads a bare
    /// `+` as a space.
    func url(container: String? = nil, key: String? = nil, query: [(name: String, value: String)] = []) -> URL {
        var path = ""
        if let container {
            path += "/" + StrictPercentEncoding.component(container)
            if let key { path += "/" + StrictPercentEncoding.key(key) }
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(account).\(blobSuffix)"
        components.percentEncodedPath = path
        if !query.isEmpty { components.percentEncodedQuery = StrictPercentEncoding.query(query) }
        return components.url!
    }
}

enum AzureBlobError: Error, Sendable {
    case notHTTPResponse
    case httpError(status: Int, code: String?, message: String)
    case malformedResponse
}

/// Per-task delegate that forwards URLSession's send-progress callbacks, offset by
/// the bytes already committed in prior blocks of a staged upload.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

/// A thin, hand-rolled Blob REST client over URLSession. Hand-rolling (rather than
/// an SDK) is deliberate: the app controls exactly which REST operation each call
/// uses, which is what makes deterministic Event Grid prediction possible. Covers
/// List Containers / List Blobs, Get Blob Properties, Get Blob, and the two write
/// paths (Put Blob, Put Block + Put Block List).
struct AzureBlobRESTClient: Sendable {

    let endpoint: AzureStorageEndpoint
    let tokenSource: any AzureTokenSource
    /// Bearer auth is rejected below `2017-11-09`; a current version is used so the
    /// full modern property set (AccessTier, etc.) comes back.
    let apiVersion: String
    let session: URLSession
    /// Downloads need a session we own to get byte progress, so they don't go through
    /// `session` — see `DownloadSession`.
    let downloader: DownloadSession
    let retryPolicy: RetryPolicy

    /// Backstop against a server that never stops returning a NextMarker.
    private static let maxPages = 1000

    init(
        endpoint: AzureStorageEndpoint,
        tokenSource: any AzureTokenSource,
        apiVersion: String = "2021-12-02",
        session: URLSession = .shared,
        downloader: DownloadSession = .shared,
        retryPolicy: RetryPolicy = .standard
    ) {
        self.endpoint = endpoint
        self.tokenSource = tokenSource
        self.apiVersion = apiVersion
        self.session = session
        self.downloader = downloader
        self.retryPolicy = retryPolicy
    }

    // MARK: - List Containers

    /// Enumerates every container in the account, following NextMarker pages.
    func listAllContainers() async throws -> [StorageContainer] {
        var results: [StorageContainer] = []
        var marker: String?
        var page = 0
        repeat {
            var query = [(name: "comp", value: "list")]
            if let marker { query.append((name: "marker", value: marker)) }

            let data = try await get(endpoint.url(query: query))
            let parsed = try ContainerListXMLParser().parse(data)
            results.append(contentsOf: parsed.containers)
            marker = parsed.nextMarker
            page += 1
        } while marker != nil && page < Self.maxPages
        return results
    }

    // MARK: - List Blobs

    /// Lists blobs under `prefix` in `container`. With `delimiter = "/"` the service
    /// collapses everything below the next slash into BlobPrefix "folders", which is
    /// what the hierarchical browser wants. Follows NextMarker pages.
    func listAllBlobs(
        inContainer container: String,
        prefix: String = "",
        delimiter: String? = "/",
        onPage: (@Sendable ([StorageObject]) async -> Void)? = nil
    ) async throws -> [StorageObject] {
        var results: [StorageObject] = []
        var marker: String?
        var page = 0
        repeat {
            var query = [
                (name: "restype", value: "container"),
                (name: "comp", value: "list"),
            ]
            if !prefix.isEmpty { query.append((name: "prefix", value: prefix)) }
            if let delimiter { query.append((name: "delimiter", value: delimiter)) }
            if let marker { query.append((name: "marker", value: marker)) }

            let data = try await get(endpoint.url(container: container, query: query))
            let parsed = try BlobListXMLParser().parse(data)
            results.append(contentsOf: parsed.objects)
            await onPage?(parsed.objects)
            marker = parsed.nextMarker
            page += 1
        } while marker != nil && page < Self.maxPages
        return results
    }

    // MARK: - Get Blob Properties (HEAD)

    /// Full metadata for a single blob. Header names are read case-insensitively.
    func fetchProperties(container: String, blobKey: String) async throws -> ObjectMetadata {
        let url = blobURL(container: container, blobKey: blobKey)
        let (_, response) = try await perform(method: "HEAD", url: url, body: nil, extraHeaders: [:])
        return ObjectMetadata(from: response)
    }

    // MARK: - Get Blob (download)

    /// Streams a blob to `destinationURL` using a URLSession *download* task, so the
    /// bytes go straight to disk and memory stays flat regardless of blob size.
    /// Replaces anything already at the destination. Reads emit no storage event.
    func downloadBlob(
        container: String,
        key: String,
        to destinationURL: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
        try await retryingOnceIfRejected {
            try await retryPolicy.run {
                try await downloadBlobOnce(container: container, key: key, to: destinationURL, onProgress: onProgress)
            }
        }
    }

    private func downloadBlobOnce(
        container: String,
        key: String,
        to destinationURL: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
        let url = blobURL(container: container, blobKey: key)
        let token = try await tokenSource.token(asOf: Date())
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(apiVersion, forHTTPHeaderField: "x-ms-version")

        let (temporaryURL, http) = try await downloader.download(request, onProgress: onProgress)

        // The downloader hands us a file we own; make sure it never leaks, including
        // on the error paths below.
        var consumed = false
        defer { if !consumed { try? FileManager.default.removeItem(at: temporaryURL) } }

        guard (200..<300).contains(http.statusCode) else {
            // A failed GET still writes a body — Azure's error XML — to the temp file.
            let body = (try? String(contentsOf: temporaryURL, encoding: .utf8)) ?? ""
            throw Self.failure(status: http.statusCode, body: body, response: http, account: endpoint.account)
        }

        // Move into place. `replaceItemAt` is atomic and handles the
        // already-exists case; it needs the destination to exist, so fall back to a
        // plain move when it does not.
        let manager = FileManager.default
        if manager.fileExists(atPath: destinationURL.path) {
            _ = try manager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try manager.moveItem(at: temporaryURL, to: destinationURL)
        }
        consumed = true
    }

    // MARK: - Writes

    /// Single-shot upload from a file. Emits `PutBlob`.
    func putBlob(container: String, key: String, fileURL: URL, contentType: String?, onProgress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        let url = blobURL(container: container, blobKey: key)
        var headers = ["x-ms-blob-type": "BlockBlob"]
        if let contentType { headers["Content-Type"] = contentType }
        let total = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        let delegate = onProgress.map { UploadProgressDelegate(baseOffset: 0, totalBytes: total, onProgress: $0) }
        _ = try await perform(method: "PUT", url: url, body: .file(fileURL), extraHeaders: headers, delegate: delegate)
    }

    /// Staged upload from a file: Put Block × N, then Put Block List. Emits
    /// `PutBlockList` on commit (even for a single block). Memory stays bounded
    /// at one block (8 MiB default).
    func putBlockList(container: String, key: String, fileURL: URL, contentType: String?, blockSize: Int = 8 * 1024 * 1024, onProgress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        let size = max(1, blockSize)
        let total = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var blockIDs: [String] = []
        var offset: Int64 = 0
        var index = 0
        while true {
            guard let chunk = try handle.read(upToCount: size), !chunk.isEmpty else { break }
            let blockID = Data(String(format: "block-%08d", index).utf8).base64EncodedString()

            // base64 can contain + / =, which the strict encoding escapes.
            let blockURL = endpoint.url(container: container, key: key, query: [
                (name: "comp", value: "block"),
                (name: "blockid", value: blockID),
            ])
            // Progress accumulates across blocks: this block's bytes offset by the
            // bytes already committed.
            let delegate = onProgress.map { UploadProgressDelegate(baseOffset: offset, totalBytes: total, onProgress: $0) }
            _ = try await perform(method: "PUT", url: blockURL, body: .data(chunk), extraHeaders: [:], delegate: delegate)
            blockIDs.append(blockID)
            offset += Int64(chunk.count)
            index += 1
        }
        // An empty file still needs one commit with zero blocks.

        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<BlockList>\n"
        for id in blockIDs { xml += "  <Latest>\(id)</Latest>\n" }
        xml += "</BlockList>"

        let blockListURL = endpoint.url(container: container, key: key, query: [(name: "comp", value: "blocklist")])
        var headers = ["Content-Type": "application/xml"]
        if let contentType { headers["x-ms-blob-content-type"] = contentType }
        _ = try await perform(method: "PUT", url: blockListURL, body: .data(Data(xml.utf8)), extraHeaders: headers)
    }

    // MARK: - Delete Blob

    /// Removes a blob. Deleting a key that isn't there is treated as success: that is
    /// the outcome the caller asked for, and it makes retrying a partly-failed folder
    /// delete safe.
    ///
    /// A blob with snapshots refuses a plain delete with 409 `SnapshotsPresent`. The
    /// header that overrides this is sent only on that retry rather than always, because
    /// it isn't accepted on a hierarchical-namespace account's directories.
    ///
    /// A folder's key ends in `/`. On a flat account that names a zero-byte marker blob
    /// and is deleted exactly as written — stripping the slash would delete a sibling
    /// blob that happens to share the folder's name. A hierarchical-namespace account
    /// has no blob at `logs/`: it answers `400 InvalidUri`, and the directory itself
    /// lives at `logs`. A flat account never gives that answer for a well-formed name,
    /// so it is safe to read as "this is a directory" and retry without the slash.
    func deleteBlob(container: String, key: String) async throws {
        let url = blobURL(container: container, blobKey: key)
        do {
            _ = try await perform(method: "DELETE", url: url, body: nil, extraHeaders: [:])
        } catch let error as AzureBlobError {
            guard case let .httpError(status, code, _) = error else { throw error }
            switch (status, code) {
            case (404, _):
                return
            case (400, "InvalidUri") where key.hasSuffix("/") && key.count > 1:
                try await deleteBlob(container: container, key: String(key.dropLast()))
            case (409, "SnapshotsPresent"):
                _ = try await perform(
                    method: "DELETE",
                    url: url,
                    body: nil,
                    extraHeaders: ["x-ms-delete-snapshots": "include"]
                )
            default:
                throw error
            }
        }
    }

    // MARK: - Get Blob Service Properties

    /// The account's retention settings, which decide whether a delete can be undone.
    ///
    /// This is an account-level read, so it is cached by the provider rather than asked
    /// per container — and a caller that can write blobs may still not be allowed to ask
    /// it, which is why the provider treats a failure as "unknown" rather than an error.
    func retentionPolicy() async throws -> (versioningEnabled: Bool, retentionDays: Int?) {
        let data = try await get(endpoint.url(query: [
            (name: "restype", value: "service"),
            (name: "comp", value: "properties"),
        ]))
        let parsed = try BlobServicePropertiesXMLParser().parse(data)
        return (parsed.versioningEnabled, parsed.retentionDays)
    }

    // MARK: - Transport

    private enum RequestBody {
        case data(Data)
        case file(URL)
    }

    private func get(_ url: URL) async throws -> Data {
        try await perform(method: "GET", url: url, body: nil, extraHeaders: [:]).data
    }

    /// Signs, sends, and validates a request. Returns body + response so HEAD
    /// callers can read headers.
    @discardableResult
    private func perform(method: String, url: URL, body: RequestBody?, extraHeaders: [String: String], delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (data: Data, response: HTTPURLResponse) {
        // Every Blob operation Strata sends is idempotent (Put Block and Put Block
        // List included), so each can simply be sent again.
        try await retryingOnceIfRejected {
            try await retryPolicy.run {
                try await performOnce(method: method, url: url, body: body, extraHeaders: extraHeaders, delegate: delegate)
            }
        }
    }

    /// A token can be refused while the cache still thinks it's good: revoked, or
    /// minted for a different `az login` than the one now active. Dropping it and
    /// asking once more costs one request, and saves the user from reconnecting.
    private func retryingOnceIfRejected<T>(_ attempt: () async throws -> T) async throws -> T {
        do {
            return try await attempt()
        } catch StorageProviderError.unauthorized {
            await tokenSource.invalidate()
            return try await attempt()
        }
    }

    private func performOnce(method: String, url: URL, body: RequestBody?, extraHeaders: [String: String], delegate: (any URLSessionTaskDelegate)?) async throws -> (data: Data, response: HTTPURLResponse) {
        let token = try await tokenSource.token(asOf: Date())
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(apiVersion, forHTTPHeaderField: "x-ms-version")
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

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
            throw AzureBlobError.notHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.failure(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "", response: http, account: endpoint.account)
        }
        return (data, http)
    }

    /// `error(...)`, marked transient when trying again could work — Azure's 503
    /// `ServerBusy` and 500 `OperationTimedOut` among them.
    static func failure(status: Int, body: String, response: HTTPURLResponse, account: String) -> any Error {
        let mapped = error(status: status, body: body, account: account)
        guard RetryPolicy.isTransient(status: status) else { return mapped }
        return TransientFailure(underlying: mapped, retryAfter: RetryPolicy.retryAfter(from: response))
    }

    /// Maps a failed response onto something the UI can explain. A 403 is not always
    /// a missing role: `AuthorizationFailure` is the account's firewall turning the
    /// request away, and `AuthenticationFailed` is the token itself being refused.
    static func error(status: Int, body: String, account: String) -> any Error {
        let code = errorCode(in: body)
        switch (status, code) {
        case (401, _), (403, "AuthenticationFailed"), (403, "InvalidAuthenticationInfo"):
            return StorageProviderError.unauthorized
        case (403, "AuthorizationFailure"):
            return StorageProviderError.networkRestricted(account: account)
        case (403, _):
            return StorageProviderError.dataPlaneForbidden(account: account)
        default:
            return AzureBlobError.httpError(status: status, code: code, message: body)
        }
    }

    private func blobURL(container: String, blobKey: String) -> URL {
        endpoint.url(container: container, key: blobKey)
    }

    /// Pulls Azure's `<Code>…</Code>` out of an error response body for diagnostics.
    private static func errorCode(in body: String) -> String? {
        guard let open = body.range(of: "<Code>"), let close = body.range(of: "</Code>"),
              open.upperBound <= close.lowerBound else { return nil }
        return String(body[open.upperBound..<close.lowerBound])
    }
}

// MARK: - Header decoding

extension ObjectMetadata {
    /// Decodes an Azure Get Blob Properties (HEAD) response.
    init(from response: HTTPURLResponse) {
        func header(_ name: String) -> String? {
            (response.value(forHTTPHeaderField: name)).flatMap { $0.isEmpty ? nil : $0 }
        }

        var custom: [String: String] = [:]
        for (rawKey, rawValue) in response.allHeaderFields {
            guard let key = (rawKey as? String)?.lowercased(), key.hasPrefix("x-ms-meta-"),
                  let value = rawValue as? String else { continue }
            custom[String(key.dropFirst("x-ms-meta-".count))] = value
        }

        var lastModified: Date?
        if let raw = header("Last-Modified") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            lastModified = formatter.date(from: raw)
        }

        self.init(
            size: header("Content-Length").flatMap { Int64($0) } ?? 0,
            contentType: header("Content-Type"),
            storageClass: header("x-ms-access-tier"),
            etag: header("Etag"),
            lastModified: lastModified,
            blobType: header("x-ms-blob-type"),
            custom: custom
        )
    }
}

// MARK: - XML parsing
//
// The List APIs return XML. Foundation's XMLParser (no dependency) is used
// synchronously inside each call — the delegates never cross an actor boundary, so
// they need not be Sendable. Internal (not private) so they can be unit-tested via
// `@testable import`.

/// Reads Get Blob Service Properties for the two settings that decide whether a delete
/// can be undone.
///
/// `<DeleteRetentionPolicy>` is scoped deliberately: the same response also carries
/// `<ContainerDeleteRetentionPolicy>`, with identically-named `Enabled` and `Days`
/// children, and picking that one up would promise recovery of blobs from a policy that
/// only ever retained whole containers.
final class BlobServicePropertiesXMLParser: NSObject, XMLParserDelegate {
    private var text = ""
    private var inBlobRetentionPolicy = false
    private var retentionEnabled = false
    private var days: Int?
    private var versioningEnabled = false

    func parse(_ data: Data) throws -> (versioningEnabled: Bool, retentionDays: Int?) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? AzureBlobError.malformedResponse
        }
        return (versioningEnabled, retentionEnabled ? days : nil)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        text = ""
        if elementName == "DeleteRetentionPolicy" { inBlobRetentionPolicy = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Enabled" where inBlobRetentionPolicy:
            retentionEnabled = value.lowercased() == "true"
        case "Days" where inBlobRetentionPolicy:
            days = Int(value)
        case "DeleteRetentionPolicy":
            inBlobRetentionPolicy = false
        case "IsVersioningEnabled":
            versioningEnabled = value.lowercased() == "true"
        default:
            break
        }
    }
}

final class ContainerListXMLParser: NSObject, XMLParserDelegate {
    private var containers: [StorageContainer] = []
    private var nextMarker: String?
    private var text = ""
    private var currentName: String?
    private var inContainer = false

    func parse(_ data: Data) throws -> (containers: [StorageContainer], nextMarker: String?) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? AzureBlobError.malformedResponse
        }
        let marker = (nextMarker?.isEmpty ?? true) ? nil : nextMarker
        return (containers, marker)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        text = ""
        if elementName == "Container" {
            inContainer = true
            currentName = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "Name" where inContainer:
            currentName = text
        case "Container":
            if let currentName { containers.append(StorageContainer(name: currentName)) }
            inContainer = false
        case "NextMarker":
            nextMarker = text
        default:
            break
        }
    }
}

final class BlobListXMLParser: NSObject, XMLParserDelegate {
    private var objects: [StorageObject] = []
    private var nextMarker: String?
    private var text = ""

    private enum Scope { case none, blob, blobPrefix }
    private var scope: Scope = .none
    private var name: String?
    private var contentLength: Int64 = 0
    private var lastModified: Date?
    private var contentType: String?
    private var accessTier: String?
    private var etag: String?

    private let rfc1123: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    func parse(_ data: Data) throws -> (objects: [StorageObject], nextMarker: String?) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? AzureBlobError.malformedResponse
        }
        let marker = (nextMarker?.isEmpty ?? true) ? nil : nextMarker
        return (objects, marker)
    }

    private func resetFields() {
        name = nil
        contentLength = 0
        lastModified = nil
        contentType = nil
        accessTier = nil
        etag = nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        text = ""
        switch elementName {
        case "Blob":
            scope = .blob
            resetFields()
        case "BlobPrefix":
            scope = .blobPrefix
            resetFields()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "Name":
            name = text
        case "Content-Length":
            contentLength = Int64(text) ?? 0
        case "Last-Modified":
            lastModified = rfc1123.date(from: text)
        case "Content-Type":
            contentType = text.isEmpty ? nil : text
        case "AccessTier":
            accessTier = text.isEmpty ? nil : text
        case "Etag":
            etag = text.isEmpty ? nil : text
        case "Blob":
            if let name {
                objects.append(StorageObject(
                    key: name,
                    size: contentLength,
                    lastModified: lastModified,
                    storageClass: accessTier,
                    contentType: contentType,
                    etag: etag
                ))
            }
            scope = .none
        case "BlobPrefix":
            if let name {
                objects.append(StorageObject(key: name, isPrefix: true))
            }
            scope = .none
        case "NextMarker":
            nextMarker = text
        default:
            break
        }
    }
}
