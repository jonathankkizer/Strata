import Testing
import AppKit
@testable import Strata

/// Drives the real Columns controller. TODO.md U10.
@Suite("Columns multi-select", .serialized)
@MainActor
struct ColumnSelectionTests {

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeColumns(_ provider: GatedProvider) -> ColumnBrowserViewController {
        let columns = ColumnBrowserViewController()
        columns.loadViewIfNeeded()
        columns.provider = provider
        return columns
    }

    @Test("One folder opens its column; several things selected just stay selected")
    func multipleSelection() async {
        let provider = GatedProvider()
        let columns = makeColumns(provider)
        var reported: [[String]] = []
        columns.onSelectionChange = { reported.append($0.map(\.key)) }
        columns.show(BrowserLocation(container: "c", prefix: ""))
        await provider.release(page: [
            StorageObject(key: "a/", isPrefix: true),
            StorageObject(key: "x.txt", size: 1),
            StorageObject(key: "y.txt", size: 1),
        ])
        await provider.finish()
        await settle { columns.rowCount(inColumnAt: 0) == 3 }

        columns.select(keys: ["a/"], inColumnAt: 0)
        #expect(columns.openColumnLocations.count == 2)
        #expect(columns.location?.prefix == "a/")

        columns.select(keys: ["a/", "x.txt", "y.txt"], inColumnAt: 0)
        #expect(columns.openColumnLocations.count == 1)
        #expect(columns.location?.prefix == "")
        #expect(Set(columns.selection.map(\.key)) == ["a/", "x.txt", "y.txt"])
        #expect(Set(columns.downloadableSelection.map(\.key)) == ["x.txt", "y.txt"])
        #expect(columns.selectedFolder == nil)
        #expect(Set(reported.last ?? []) == ["a/", "x.txt", "y.txt"])
    }

    @Test("A sort keeps a multiple selection")
    func sortKeepsSelection() async {
        let provider = GatedProvider()
        let columns = makeColumns(provider)
        columns.show(BrowserLocation(container: "c", prefix: ""))
        await provider.release(page: [StorageObject(key: "b", size: 2), StorageObject(key: "a", size: 1), StorageObject(key: "c", size: 3)])
        await provider.finish()
        await settle { columns.rowCount(inColumnAt: 0) == 3 }

        columns.select(keys: ["a", "c"], inColumnAt: 0)
        columns.applySort(BrowseSort(key: .size, ascending: false))
        #expect(Set(columns.selection.map(\.key)) == ["a", "c"])
    }
}
