import AppKit
import Testing
@testable import Strata

/// Covers what Strata puts on the pasteboard for a blob. A private pasteboard is
/// used throughout — these run on a real machine, and clobbering the user's actual
/// clipboard from a test would be rude.
@MainActor
@Suite("Blob file promise pasteboard representations")
struct BlobFilePromiseTests {

    private var pasteboard: NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.kizersolutions.strata.tests"))
    }

    private let container = StorageContainer(name: "data")
    private let provider = S3Provider(displayName: "test")

    private func makePromise(
        key: String,
        contentType: String? = nil,
        pathText: String? = nil
    ) -> BlobFilePromiseProvider? {
        BlobFilePromiseProvider.make(
            for: StorageObject(key: key, size: 10, contentType: contentType),
            in: container,
            provider: provider,
            pathText: pathText
        )
    }

    /// The deferred one. `promised-file-content-type` sounds like the promise but is
    /// written immediately — it only tells the receiver what kind of file is coming.
    private static let promisedFileName = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-name")
    private static let promisedContentType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")

    @Test("A blob offers the promised file, its path, and its URL")
    func offersAllThreeRepresentations() throws {
        let promise = try #require(makePromise(key: "raw/report.csv"))
        let types = promise.writableTypes(for: pasteboard)

        #expect(types.contains(.string))
        #expect(types.contains(.URL))
        // These two are what let the Finder receive an actual file on paste.
        #expect(types.contains(Self.promisedFileName))
        #expect(types.contains(Self.promisedContentType))
    }

    @Test("Only the file itself is deferred; text and URL are available immediately")
    func writingOptions() throws {
        let promise = try #require(makePromise(key: "raw/report.csv"))
        #expect(promise.writingOptions(forType: .string, pasteboard: pasteboard) == [])
        #expect(promise.writingOptions(forType: .URL, pasteboard: pasteboard) == [])
        // Adding our own types must not disturb how the file itself is promised.
        #expect(promise.writingOptions(forType: Self.promisedFileName, pasteboard: pasteboard).contains(.promised))
    }

    @Test("The content type comes from the blob, so the receiver knows what lands")
    func promisedContentType() throws {
        let promise = try #require(makePromise(key: "raw/report.csv"))
        let declared = promise.pasteboardPropertyList(forType: Self.promisedContentType) as? String
        #expect(declared == "public.comma-separated-values-text")
    }

    @Test("The plain-text representation is the container/key path")
    func pathText() throws {
        let promise = try #require(makePromise(key: "raw/report.csv"))
        #expect(promise.pasteboardPropertyList(forType: .string) as? String == "data/raw/report.csv")
    }

    @Test("Copy can override the text so the first item carries the whole selection")
    func pathTextOverride() throws {
        let joined = "data/a.csv\ndata/b.csv"
        let promise = try #require(makePromise(key: "a.csv", pathText: joined))
        #expect(promise.pasteboardPropertyList(forType: .string) as? String == joined)
    }

    @Test("The URL representation is the provider's object URL")
    func urlRepresentation() throws {
        let promise = try #require(makePromise(key: "raw/report.csv"))
        let url = promise.pasteboardPropertyList(forType: .URL) as? String
        #expect(url == "s3://data/raw/report.csv")
    }

    @Test("The promised file is named from the key, with the content type's extension")
    func promisedFileName() throws {
        #expect(try #require(makePromise(key: "raw/report.csv")).payload.fileName == "report.csv")
        // No extension on the key, but the content type implies one.
        let typed = try #require(makePromise(key: "raw/manifest", contentType: "application/json"))
        #expect(typed.payload.fileName == "manifest.json")
    }

    @Test("A folder has nothing to promise")
    func folderHasNoPromise() {
        let folder = BlobFilePromiseProvider.make(
            for: StorageObject(key: "raw/", isPrefix: true),
            in: container,
            provider: provider
        )
        #expect(folder == nil)
    }

    @Test("Writing to a pasteboard round-trips the text and URL")
    func writeAndReadBack() throws {
        let promise = try #require(makePromise(key: "raw/report.csv"))
        let board = pasteboard
        board.clearContents()
        #expect(board.writeObjects([promise]))
        #expect(board.string(forType: .string) == "data/raw/report.csv")
        board.clearContents()
    }
}
