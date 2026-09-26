import Testing
import Foundation
@testable import Strata

/// TODO.md F4, F11, F12.

@Suite("Kind descriptions")
struct KindDescriptionTests {

    @Test("A blob is described the way the Finder would, not by MIME type")
    func finderWords() {
        let pdf = StorageObject(key: "report.pdf", size: 1, contentType: "application/pdf")
        #expect(pdf.kindDescription == pdf.utType.localizedDescription)
        #expect(pdf.kindDescription != "application/pdf")
        #expect(StorageObject(key: "logs/", isPrefix: true).kindDescription == "Folder")
    }

    @Test("Without a content type, the extension decides")
    func fromExtension() {
        #expect(StorageObject(key: "notes.txt", size: 1).utType == .plainText)
        #expect(StorageObject(key: "mystery", size: 1).utType == .data)
    }
}

@Suite("Folder upload through a symlink")
struct SymlinkUploadTests {

    /// A link inside the dropped tree used to be keyed by its target's path: the
    /// link's name was lost and the target went up twice under one key.
    @Test("A symlinked file keeps its own name in the key")
    func symlinkKeepsName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("strata-link-\(UUID().uuidString)")
        let tree = root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: tree.appendingPathComponent("real.txt"))
        try FileManager.default.createSymbolicLink(at: tree.appendingPathComponent("alias.txt"), withDestinationURL: tree.appendingPathComponent("real.txt"))
        try Data("outside".utf8).write(to: root.appendingPathComponent("elsewhere.txt"))
        try FileManager.default.createSymbolicLink(at: tree.appendingPathComponent("escape.txt"), withDestinationURL: root.appendingPathComponent("elsewhere.txt"))

        let keys = UploadPlanning.expand(urls: [tree], prefix: "", target: .s3).map(\.key)
        #expect(keys == ["tree/alias.txt", "tree/real.txt"])
    }
}

@Suite("Preview cache pruning")
struct PreviewCachePruneTests {

    @Test("The least recently used previews go first, until the cache fits")
    func prunesOldest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("strata-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        for (index, name) in ["old", "middle", "new"].enumerated() {
            let folder = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 100_000).write(to: folder.appendingPathComponent("f.bin"))
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(index) * 60)], ofItemAtPath: folder.path)
        }

        PreviewCache.prune(directory, limit: 250_000)

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(left == ["middle", "new"])
    }
}
