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

            let data = try await send(components.url!)
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

            let data = try await send(components.url!)
            let parsed = try BlobListXMLParser().parse(data)
            results.append(contentsOf: parsed.objects)
            marker = parsed.nextMarker
            page += 1
        } while marker != nil && page < Self.maxPages
        return results
    }

    // MARK: - Transport

    private func send(_ url: URL) async throws -> Data {
        let token = try await tokenSource.token(asOf: Date())
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(apiVersion, forHTTPHeaderField: "x-ms-version")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AzureBlobError.notHTTPResponse
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw StorageProviderError.unauthorized
        case 403:
            // The RBAC trap: a valid token whose identity lacks a Storage Blob Data
            // role. Surfaced specifically rather than as a generic auth failure.
            throw StorageProviderError.dataPlaneForbidden(account: endpoint.account)
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AzureBlobError.httpError(status: http.statusCode, code: Self.errorCode(in: body), message: body)
        }
    }

    /// Pulls Azure's `<Code>…</Code>` out of an error response body for diagnostics.
    private static func errorCode(in body: String) -> String? {
        guard let open = body.range(of: "<Code>"), let close = body.range(of: "</Code>"),
              open.upperBound <= close.lowerBound else { return nil }
        return String(body[open.upperBound..<close.lowerBound])
    }
}

// MARK: - XML parsing
//
// The List APIs return XML. Foundation's XMLParser (no dependency) is used
// synchronously inside each call — the delegates never cross an actor boundary, so
// they need not be Sendable.

private final class ContainerListXMLParser: NSObject, XMLParserDelegate {
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

private final class BlobListXMLParser: NSObject, XMLParserDelegate {
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
