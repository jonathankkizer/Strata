import Testing
import Foundation
@testable import Strata

@Suite("ObjectMetadata HTTP header decoding")
struct ObjectMetadataTests {

    private let sampleURL = URL(string: "https://example.blob.core.windows.net/container/blob")!

    // MARK: - Full header set

    @Test("All standard headers decode correctly")
    func allStandardHeadersDecode() throws {
        let headers: [String: String] = [
            "Content-Length": "1234",
            "Content-Type": "application/octet-stream",
            "x-ms-access-tier": "Hot",
            "Etag": "\"abc123\"",
            "x-ms-blob-type": "BlockBlob",
            "Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT",
        ]
        let response = try #require(HTTPURLResponse(
            url: sampleURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ))
        let meta = ObjectMetadata(from: response)

        #expect(meta.size == 1234)
        #expect(meta.contentType == "application/octet-stream")
        #expect(meta.storageClass == "Hot")
        #expect(meta.etag == "\"abc123\"")
        #expect(meta.blobType == "BlockBlob")
        #expect(meta.lastModified != nil)
    }

    @Test("Last-Modified RFC1123 date decodes to non-nil Date in 2015")
    func lastModifiedDecodesCorrectly() throws {
        let headers: [String: String] = [
            "Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT",
        ]
        let response = try #require(HTTPURLResponse(
            url: sampleURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ))
        let meta = ObjectMetadata(from: response)
        let date = try #require(meta.lastModified)
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        #expect(year == 2015)
    }

    // MARK: - Custom x-ms-meta- headers

    @Test("x-ms-meta-* headers are stripped and lowercased into custom dict")
    func customMetaHeadersStripped() throws {
        let headers: [String: String] = [
            "x-ms-meta-foo": "fooValue",
            "x-ms-meta-bar": "barValue",
        ]
        let response = try #require(HTTPURLResponse(
            url: sampleURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ))
        let meta = ObjectMetadata(from: response)
        #expect(meta.custom["foo"] == "fooValue")
        #expect(meta.custom["bar"] == "barValue")
        #expect(meta.custom.count == 2)
    }

    // MARK: - Empty / missing headers

    @Test("Missing headers produce nils and size 0")
    func missingHeadersProduceDefaults() throws {
        let response = try #require(HTTPURLResponse(
            url: sampleURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        ))
        let meta = ObjectMetadata(from: response)
        #expect(meta.size == 0)
        #expect(meta.contentType == nil)
        #expect(meta.storageClass == nil)
        #expect(meta.etag == nil)
        #expect(meta.blobType == nil)
        #expect(meta.lastModified == nil)
        #expect(meta.custom.isEmpty)
    }

    @Test("Empty Content-Length header produces size 0")
    func emptyContentLengthIsZero() throws {
        let response = try #require(HTTPURLResponse(
            url: sampleURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": ""]
        ))
        let meta = ObjectMetadata(from: response)
        #expect(meta.size == 0)
    }

    @Test("Empty Content-Type header produces nil contentType")
    func emptyContentTypeIsNil() throws {
        let response = try #require(HTTPURLResponse(
            url: sampleURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": ""]
        ))
        let meta = ObjectMetadata(from: response)
        #expect(meta.contentType == nil)
    }
}
