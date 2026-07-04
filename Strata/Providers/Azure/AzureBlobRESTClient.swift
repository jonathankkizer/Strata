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

    var baseURL: URL {
        URL(string: "https://\(account).\(blobSuffix)")!
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
/// uses, which is what makes deterministic Event Grid prediction possible. Reads
/// only — List Containers / List Blobs — for the first cut.
struct AzureBlobRESTClient: Sendable {

    let endpoint: AzureStorageEndpoint
    let tokenSource: any AzureTokenSource
    /// Bearer auth is rejected below `2017-11-09`; a current version is used so the
    /// full modern property set (AccessTier, etc.) comes back.
    let apiVersion: String
    let session: URLSession

    /// Backstop against a server that never stops returning a NextMarker.
    private static let maxPages = 1000

    init(
        endpoint: AzureStorageEndpoint,
        tokenSource: any AzureTokenSource,
        apiVersion: String = "2021-12-02",
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.tokenSource = tokenSource
        self.apiVersion = apiVersion
        self.session = session
    }

    // MARK: - List Containers

    /// Enumerates every container in the account, following NextMarker pages.
    func listAllContainers() async throws -> [StorageContainer] {
        var results: [StorageContainer] = []
        var marker: String?
        var page = 0
        repeat {
            var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "comp", value: "list")]
            if let marker { components.queryItems?.append(URLQueryItem(name: "marker", value: marker)) }

            let data = try await get(components.url!)
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
    func listAllBlobs(inContainer container: String, prefix: String = "", delimiter: String? = "/") async throws -> [StorageObject] {
        var results: [StorageObject] = []
        var marker: String?
        var page = 0
        let containerURL = endpoint.baseURL.appendingPathComponent(container)
        repeat {
            var components = URLComponents(url: containerURL, resolvingAgainstBaseURL: false)!
            var query = [
                URLQueryItem(name: "restype", value: "container"),
                URLQueryItem(name: "comp", value: "list"),
            ]
            if !prefix.isEmpty { query.append(URLQueryItem(name: "prefix", value: prefix)) }
            if let delimiter { query.append(URLQueryItem(name: "delimiter", value: delimiter)) }
            if let marker { query.append(URLQueryItem(name: "marker", value: marker)) }
            components.queryItems = query

            let data = try await get(components.url!)
            let parsed = try BlobListXMLParser().parse(data)
            results.append(contentsOf: parsed.objects)
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
        let url = blobURL(container: container, blobKey: key)
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

            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.percentEncodedQueryItems = [
                URLQueryItem(name: "comp", value: "block"),
                // base64 can contain + / = — encode the whole value so the query is valid.
                URLQueryItem(name: "blockid", value: blockID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? blockID),
            ]
            // Progress accumulates across blocks: this block's bytes offset by the
            // bytes already committed.
            let delegate = onProgress.map { UploadProgressDelegate(baseOffset: offset, totalBytes: total, onProgress: $0) }
            _ = try await perform(method: "PUT", url: components.url!, body: .data(chunk), extraHeaders: [:], delegate: delegate)
            blockIDs.append(blockID)
            offset += Int64(chunk.count)
            index += 1
        }
        // An empty file still needs one commit with zero blocks.

        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<BlockList>\n"
        for id in blockIDs { xml += "  <Latest>\(id)</Latest>\n" }
        xml += "</BlockList>"

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "comp", value: "blocklist")]
        var headers = ["Content-Type": "application/xml"]
        if let contentType { headers["x-ms-blob-content-type"] = contentType }
        _ = try await perform(method: "PUT", url: components.url!, body: .data(Data(xml.utf8)), extraHeaders: headers)
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
    /// callers can read headers. Maps the 403 RBAC trap and 401 specifically.
    @discardableResult
    private func perform(method: String, url: URL, body: RequestBody?, extraHeaders: [String: String], delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (data: Data, response: HTTPURLResponse) {
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
        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 401:
            throw StorageProviderError.unauthorized
        case 403:
            throw StorageProviderError.dataPlaneForbidden(account: endpoint.account)
        default:
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw AzureBlobError.httpError(status: http.statusCode, code: Self.errorCode(in: bodyString), message: bodyString)
        }
    }

    /// Builds a blob URL, appending each path segment so embedded slashes are
    /// preserved as real path separators.
    private func blobURL(container: String, blobKey: String) -> URL {
        var url = endpoint.baseURL.appendingPathComponent(container)
        for segment in blobKey.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(segment))
        }
        return url
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
