import Foundation

/// S3's list APIs return XML. Parsed with Foundation's `XMLParser` — the same choice,
/// and the same streaming-delegate shape, as the Azure list parsers, so there is one
/// pattern in the codebase rather than two.
///
/// Internal rather than private so `@testable` can reach them: these parsers decide
/// what the browser shows, and a listing that silently drops keys or mis-reads a size
/// is the kind of bug that is invisible until it matters.

// MARK: - ListBuckets

final class S3BucketListXMLParser: NSObject, XMLParserDelegate {

    private var buckets: [StorageContainer] = []
    private var currentElement = ""
    private var currentText = ""
    private var currentName: String?
    private var parseError: (any Error)?

    func parse(_ data: Data) throws -> [StorageContainer] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parseError ?? S3Error.malformedResponse
        }
        return buckets
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        currentElement = elementName
        currentText = ""
        if elementName == "Bucket" { currentName = nil }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Name":
            currentName = text
        case "Bucket":
            if let name = currentName, !name.isEmpty {
                // ListBuckets doesn't report a region per bucket; it's resolved
                // separately, on demand.
                buckets.append(StorageContainer(name: name))
            }
            currentName = nil
        default:
            break
        }
        currentText = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: any Error) {
        parseError = error
    }
}

// MARK: - ListObjectsV2

/// One page of a listing: objects, "folders", and the token for the next page.
struct S3ObjectPage: Sendable, Equatable {
    var objects: [StorageObject]
    var continuationToken: String?
    var isTruncated: Bool
}

final class S3ObjectListXMLParser: NSObject, XMLParserDelegate {

    private var objects: [StorageObject] = []
    private var continuationToken: String?
    private var isTruncated = false

    private var currentText = ""
    private var inContents = false
    private var inCommonPrefixes = false

    private var key: String?
    private var size: Int64 = 0
    private var lastModified: Date?
    private var etag: String?
    private var storageClass: String?

    private var parseError: (any Error)?

    /// S3 timestamps are ISO 8601 with milliseconds. Instance-level rather than static
    /// because `ISO8601DateFormatter` isn't `Sendable`; a parser is created per page, so
    /// this is still built once per listing rather than once per row.
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let fallbackDateFormatter = ISO8601DateFormatter()

    func parse(_ data: Data) throws -> S3ObjectPage {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parseError ?? S3Error.malformedResponse
        }
        return S3ObjectPage(
            objects: objects,
            continuationToken: continuationToken,
            isTruncated: isTruncated
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        currentText = ""
        switch elementName {
        case "Contents":
            inContents = true
            resetFields()
        case "CommonPrefixes":
            inCommonPrefixes = true
            key = nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Key" where inContents:
            key = text
        case "Prefix" where inCommonPrefixes:
            key = text
        case "Size":
            size = Int64(text) ?? 0
        case "LastModified":
            lastModified = dateFormatter.date(from: text) ?? fallbackDateFormatter.date(from: text)
        case "ETag":
            // S3 quotes ETags in XML exactly as in the header.
            etag = text
        case "StorageClass":
            storageClass = text
        case "NextContinuationToken":
            continuationToken = text.isEmpty ? nil : text
        case "IsTruncated":
            isTruncated = (text == "true")
        case "Contents":
            if let key, !key.isEmpty, !key.hasSuffix("/") || size > 0 {
                objects.append(StorageObject(
                    key: key,
                    size: size,
                    lastModified: lastModified,
                    storageClass: storageClass,
                    etag: etag,
                    isPrefix: false
                ))
            }
            inContents = false
            resetFields()
        case "CommonPrefixes":
            if let key, !key.isEmpty {
                objects.append(StorageObject(key: key, isPrefix: true))
            }
            inCommonPrefixes = false
            self.key = nil
        default:
            break
        }
        currentText = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: any Error) {
        parseError = error
    }

    private func resetFields() {
        key = nil
        size = 0
        lastModified = nil
        etag = nil
        storageClass = nil
    }
}

// MARK: - Errors and small responses

/// S3 error bodies are XML: `<Error><Code>..</Code><Message>..</Message></Error>`.
/// The code is what distinguishes "no such bucket" from "access denied", which is the
/// difference between a useful message and a shrug.
enum S3ErrorXMLParser {

    static func code(in body: String) -> String? {
        element("Code", in: body)
    }

    static func message(in body: String) -> String? {
        element("Message", in: body)
    }

    /// Also used for the single-value responses (`GetBucketLocation`,
    /// `CreateMultipartUpload`'s `UploadId`), which don't warrant a delegate parser.
    static func element(_ name: String, in body: String) -> String? {
        guard let start = body.range(of: "<\(name)>"),
              let end = body.range(of: "</\(name)>", range: start.upperBound..<body.endIndex) else {
            return nil
        }
        let value = String(body[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
