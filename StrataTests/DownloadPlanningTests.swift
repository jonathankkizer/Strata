import Foundation
import Testing
@testable import Strata

@Suite("DownloadPlanning.fileName")
struct DownloadPlanningFileNameTests {

    @Test("A flat key is its own file name")
    func flatKey() {
        #expect(DownloadPlanning.fileName(forKey: "report.csv") == "report.csv")
    }

    @Test("A nested key uses only the last segment")
    func nestedKey() {
        #expect(DownloadPlanning.fileName(forKey: "raw/2026/07/report.csv") == "report.csv")
    }

    @Test("A folder-marker key falls back to the last real segment")
    func folderMarkerKey() {
        #expect(DownloadPlanning.fileName(forKey: "raw/2026/") == "2026")
    }

    @Test("An empty or slash-only key yields a placeholder rather than an empty name")
    func degenerateKeys() {
        #expect(DownloadPlanning.fileName(forKey: "") == "Untitled")
        #expect(DownloadPlanning.fileName(forKey: "///") == "Untitled")
    }

    @Test("A dot-prefixed key is not written as a hidden file")
    func dotPrefixedKey() {
        // The user asked to download a blob, not to create an invisible file.
        #expect(DownloadPlanning.fileName(forKey: "config/.env") == "Blob .env")
    }

    @Test("The content type's extension is appended only when the key has none")
    func preferredExtension() {
        #expect(DownloadPlanning.fileName(forKey: "raw/manifest", preferredExtension: "json") == "manifest.json")
        // Already extended: leave it alone rather than double-extending.
        #expect(DownloadPlanning.fileName(forKey: "raw/manifest.json", preferredExtension: "json") == "manifest.json")
        // A conflicting-but-present extension is still the user's, so it wins.
        #expect(DownloadPlanning.fileName(forKey: "raw/data.csv", preferredExtension: "txt") == "data.csv")
    }

    @Test("An absent or empty preferred extension changes nothing")
    func noPreferredExtension() {
        #expect(DownloadPlanning.fileName(forKey: "raw/manifest", preferredExtension: nil) == "manifest")
        #expect(DownloadPlanning.fileName(forKey: "raw/manifest", preferredExtension: "") == "manifest")
    }
}

@Suite("DownloadPlanning.uniqueURL")
struct DownloadPlanningUniqueURLTests {

    private let directory = URL(fileURLWithPath: "/tmp/strata-tests", isDirectory: true)

    @Test("An unused name is returned unchanged")
    func noCollision() {
        let url = DownloadPlanning.uniqueURL(fileName: "report.csv", in: directory) { _ in false }
        #expect(url.lastPathComponent == "report.csv")
    }

    @Test("A collision disambiguates Finder-style, before the extension")
    func singleCollision() {
        let taken: Set<String> = ["report.csv"]
        let url = DownloadPlanning.uniqueURL(fileName: "report.csv", in: directory) {
            taken.contains($0.lastPathComponent)
        }
        #expect(url.lastPathComponent == "report 2.csv")
    }

    @Test("Repeated collisions keep counting up")
    func repeatedCollisions() {
        let taken: Set<String> = ["report.csv", "report 2.csv", "report 3.csv"]
        let url = DownloadPlanning.uniqueURL(fileName: "report.csv", in: directory) {
            taken.contains($0.lastPathComponent)
        }
        #expect(url.lastPathComponent == "report 4.csv")
    }

    @Test("A name without an extension disambiguates with no trailing dot")
    func extensionlessCollision() {
        let taken: Set<String> = ["manifest"]
        let url = DownloadPlanning.uniqueURL(fileName: "manifest", in: directory) {
            taken.contains($0.lastPathComponent)
        }
        #expect(url.lastPathComponent == "manifest 2")
    }

    @Test("A multi-dot name only treats the final component as the extension")
    func multiDotName() {
        let taken: Set<String> = ["archive.tar.gz"]
        let url = DownloadPlanning.uniqueURL(fileName: "archive.tar.gz", in: directory) {
            taken.contains($0.lastPathComponent)
        }
        #expect(url.lastPathComponent == "archive.tar 2.gz")
    }

    @Test("The result always lands in the requested directory")
    func staysInDirectory() {
        let url = DownloadPlanning.uniqueURL(fileName: "report.csv", in: directory) { _ in false }
        #expect(url.deletingLastPathComponent().path == directory.path)
    }
}
