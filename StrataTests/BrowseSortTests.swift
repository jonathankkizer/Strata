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

@Suite("Browse sort ordering")
struct BrowseSortOrderingTests {

    private func blob(_ key: String, size: Int64 = 0) -> StorageObject {
        StorageObject(key: key, size: size)
    }

    /// `sort(by:)` requires a strict ordering. The old descending comparator said equal
    /// items were in order both ways round, which scrambled rows of equal size.
    @Test("Descending never calls equal items ordered both ways")
    func strictDescending() {
        for key in SortKey.allCases {
            let sort = BrowseSort(key: key, ascending: false)
            let a = blob("same", size: 5)
            #expect(!sort.areInOrder(a, a))
        }
    }

    @Test("Equal sizes fall back to name order, in both directions")
    func tieBreak() {
        let items = [blob("b", size: 1), blob("a", size: 1), blob("c", size: 1)]
        #expect(items.sorted(by: BrowseSort(key: .size, ascending: true).areInOrder).map(\.key) == ["a", "b", "c"])
        #expect(items.sorted(by: BrowseSort(key: .size, ascending: false).areInOrder).map(\.key) == ["a", "b", "c"])
    }

    @Test("Merging a page gives the same result as sorting everything")
    func mergeMatchesSort() {
        let sort = BrowseSort(key: .size, ascending: false)
        let first = (0..<50).map { blob("k\($0)", size: Int64($0 % 7)) }
        let second = (50..<120).map { blob("k\($0)", size: Int64($0 % 5)) } + [StorageObject(key: "dir/", isPrefix: true)]
        let merged = sort.merging(second, into: first.sorted(by: sort.areInOrder))
        #expect(merged.map(\.key) == (first + second).sorted(by: sort.areInOrder).map(\.key))
    }
}
