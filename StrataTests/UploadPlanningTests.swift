import Testing
import Foundation
@testable import Strata

@Suite("UploadPlanning.expand")
struct UploadPlanningTests {

    // MARK: - Helpers

    /// Creates a uniquely-named temp directory under the system temp dir.
    private func makeRoot(name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UploadPlanningTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Single loose file with prefix

    @Test("Single loose file with non-empty prefix is keyed as prefix+filename")
    func singleLooseFileWithPrefix() throws {
        let root = try makeRoot(name: "single")
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("hello.txt")
        let content = Data("hello world".utf8)
        try content.write(to: fileURL)

        let results = UploadPlanning.expand(urls: [fileURL], prefix: "a/b/")

        #expect(results.count == 1)
        let upload = try #require(results.first)
        #expect(upload.key == "a/b/hello.txt")
        #expect(upload.plan.byteCount == Int64(content.count))
        #expect(upload.contentType == "text/plain")
    }

    @Test("Single .jpg file gets image/jpeg content type")
    func singleJpgFile() throws {
        let root = try makeRoot(name: "jpg")
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("photo.jpg")
        // Minimal JPEG header bytes; UTType only cares about extension here
        try Data([0xFF, 0xD8, 0xFF]).write(to: fileURL)

        let results = UploadPlanning.expand(urls: [fileURL], prefix: "a/b/")

        #expect(results.count == 1)
        let upload = try #require(results.first)
        #expect(upload.key == "a/b/photo.jpg")
        #expect(upload.contentType == "image/jpeg")
    }

    // MARK: - Directory expansion

    @Test("Directory with nested files, hidden file, and empty subdir — correct keys")
    func directoryExpansion() throws {
        let root = try makeRoot(name: "dir")
        defer { try? FileManager.default.removeItem(at: root) }

        // Build: root/photos/a.jpg, photos/nested/b.png, photos/.DS_Store, photos/empty/
        let photosDir = root.appendingPathComponent("photos", isDirectory: true)
        let nestedDir = photosDir.appendingPathComponent("nested", isDirectory: true)
        let emptyDir = photosDir.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        try Data([0xFF, 0xD8, 0xFF]).write(to: photosDir.appendingPathComponent("a.jpg"))
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: nestedDir.appendingPathComponent("b.png"))
        try Data("junk".utf8).write(to: photosDir.appendingPathComponent(".DS_Store"))

        let results = UploadPlanning.expand(urls: [photosDir], prefix: "a/b/")

        let keys = results.map(\.key).sorted()
        #expect(keys == ["a/b/photos/a.jpg", "a/b/photos/nested/b.png"])
    }

    @Test("Nested file byte count matches bytes written")
    func nestedFileByteCount() throws {
        let root = try makeRoot(name: "bytecount")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = root.appendingPathComponent("data", isDirectory: true)
        let subDir = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let nestedContent = Data(repeating: 0xAB, count: 42)
        try nestedContent.write(to: subDir.appendingPathComponent("file.bin"))

        let results = UploadPlanning.expand(urls: [dir], prefix: "")
        let nested = try #require(results.first { $0.key.hasSuffix("file.bin") })
        #expect(nested.plan.byteCount == Int64(nestedContent.count))
    }

    // MARK: - Mixed input

    @Test("Mixed [folder, looseFile] input is sorted by key")
    func mixedInputSortedByKey() throws {
        let root = try makeRoot(name: "mixed")
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("zoo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("z".utf8).write(to: folder.appendingPathComponent("z.txt"))

        let looseFile = root.appendingPathComponent("aardvark.txt")
        try Data("a".utf8).write(to: looseFile)

        // folder key would be "zoo/z.txt", loose file key "aardvark.txt" — sorted: aardvark first
        let results = UploadPlanning.expand(urls: [folder, looseFile], prefix: "")
        let keys = results.map(\.key)
        #expect(keys == keys.sorted())
    }

    // MARK: - Empty prefix

    @Test("Empty prefix with a single loose file keys as just the filename")
    func emptyPrefixLooseFile() throws {
        let root = try makeRoot(name: "emptyprefix")
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("readme.txt")
        try Data("readme".utf8).write(to: fileURL)

        let results = UploadPlanning.expand(urls: [fileURL], prefix: "")

        #expect(results.count == 1)
        #expect(results[0].key == "readme.txt")
    }

    // MARK: - Byte counts

    @Test("Byte count for loose file matches bytes written")
    func looseFileByteCount() throws {
        let root = try makeRoot(name: "loosecount")
        defer { try? FileManager.default.removeItem(at: root) }

        let content = Data(repeating: 0x42, count: 99)
        let fileURL = root.appendingPathComponent("data.bin")
        try content.write(to: fileURL)

        let results = UploadPlanning.expand(urls: [fileURL], prefix: "")
        let upload = try #require(results.first)
        #expect(upload.plan.byteCount == Int64(content.count))
    }
}
