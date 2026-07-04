import Testing
import Foundation
@testable import Strata

@Suite("Browse sort")
struct BrowseSortTests {

    private func blob(_ key: String, size: Int64 = 0, modified: Date? = nil, tier: String? = nil, type: String? = nil) -> StorageObject {
        StorageObject(key: key, size: size, lastModified: modified, storageClass: tier, contentType: type)
    }
    private func folder(_ key: String) -> StorageObject {
        StorageObject(key: key, isPrefix: true)
    }

    private func sortedKeys(_ objects: [StorageObject], _ sort: BrowseSort) -> [String] {
        objects.sorted(by: sort.areInOrder).map(\.key)
    }

    @Test("Folders always sort before blobs, regardless of field or direction")
    func foldersFirst() {
        let items = [blob("a"), folder("z/"), blob("m")]
        for sort in [BrowseSort(key: .name, ascending: true), BrowseSort(key: .size, ascending: false)] {
            #expect(sortedKeys(items, sort).first == "z/")
        }
    }

    @Test("Name sorts naturally, and direction flips it")
    func nameSort() {
        let items = [blob("file10"), blob("file2"), blob("file1")]
        #expect(sortedKeys(items, BrowseSort(key: .name, ascending: true)) == ["file1", "file2", "file10"])
        #expect(sortedKeys(items, BrowseSort(key: .name, ascending: false)) == ["file10", "file2", "file1"])
    }

    @Test("Size sorts by byte count")
    func sizeSort() {
        let items = [blob("big", size: 900), blob("small", size: 5), blob("mid", size: 100)]
        #expect(sortedKeys(items, BrowseSort(key: .size, ascending: true)) == ["small", "mid", "big"])
    }

    @Test("Date Modified sorts chronologically; missing dates sort earliest")
    func dateSort() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [
            blob("newer", modified: base.addingTimeInterval(3600)),
            blob("older", modified: base),
            blob("undated", modified: nil),
        ]
        #expect(sortedKeys(items, BrowseSort(key: .dateModified, ascending: true)) == ["undated", "older", "newer"])
    }

    @Test("Kind sorts by content type; Tier sorts by access tier")
    func kindAndTierSort() {
        let kindItems = [blob("z", type: "text/plain"), blob("a", type: "application/pdf")]
        #expect(sortedKeys(kindItems, BrowseSort(key: .kind, ascending: true)) == ["a", "z"])

        let tierItems = [blob("hot", tier: "Hot"), blob("archive", tier: "Archive"), blob("cool", tier: "Cool")]
        #expect(sortedKeys(tierItems, BrowseSort(key: .tier, ascending: true)) == ["archive", "cool", "hot"])
    }
}
