import AppKit
import Testing
@testable import Strata

@MainActor
@Suite("Favorite")
struct FavoriteTests {

    @Test("A folder favorite is named for its deepest segment")
    func folderName() {
        let favorite = Favorite(account: .azure("acct"), container: "data", prefix: "raw/2026/")
        #expect(favorite.displayName == "2026")
        #expect(!favorite.isContainerRoot)
    }

    @Test("A container favorite is named for the container")
    func containerName() {
        let favorite = Favorite(account: .azure("acct"), container: "data", prefix: "")
        #expect(favorite.displayName == "data")
        #expect(favorite.isContainerRoot)
    }

    @Test("A custom name wins, and an empty one falls back to the folder")
    func customName() {
        var favorite = Favorite(account: .azure("acct"), container: "data", prefix: "raw/", customName: "Landing zone")
        #expect(favorite.displayName == "Landing zone")
        favorite.customName = ""
        #expect(favorite.displayName == "raw")
    }

    @Test("Sameness is about the place, not the name")
    func sameness() {
        let a = Favorite(account: .azure("acct"), container: "data", prefix: "raw/", customName: "One")
        let b = Favorite(account: .azure("acct"), container: "data", prefix: "raw/", customName: "Two")
        let elsewhere = Favorite(account: .azure("other"), container: "data", prefix: "raw/")
        #expect(a.refersToSamePlace(as: b))
        #expect(!a.refersToSamePlace(as: elsewhere))
    }

    @Test("A favorite round-trips its location")
    func location() {
        let favorite = Favorite(account: .azure("acct"), location: BrowserLocation(container: "data", prefix: "raw/2026/"))
        #expect(favorite.location == BrowserLocation(container: "data", prefix: "raw/2026/"))
    }
}

@MainActor
@Suite("Favorites store")
struct FavoritesStoreTests {

    /// Each test gets its own defaults suite, since Swift Testing runs tests in
    /// parallel, and cleans up after itself rather than leaving plists behind.
    private func withStore(_ body: (FavoritesStore, UserDefaults) throws -> Void) rethrows {
        let name = "com.kizersolutions.strata.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            UserDefaults.standard.removeSuite(named: name)
        }
        try body(FavoritesStore(defaults: defaults), defaults)
    }

    private func favorite(_ prefix: String, account: ProviderAccount = .azure("acct")) -> Favorite {
        Favorite(account: account, container: "data", prefix: prefix)
    }

    @Test("A new store is empty")
    func startsEmpty() {
        withStore { store, _ in
            #expect(store.isEmpty)
        }
    }

    @Test("Adding the same place twice is refused")
    func duplicatesRefused() {
        withStore { store, _ in
            #expect(store.add(favorite("raw/")))
            #expect(!store.add(favorite("raw/")))
            #expect(store.favorites.count == 1)
        }
    }

    @Test("The same folder in a different account is a different place")
    func perAccount() {
        withStore { store, _ in
            #expect(store.add(favorite("raw/", account: .azure("one"))))
            #expect(store.add(favorite("raw/", account: .azure("two"))))
            #expect(store.favorites.count == 2)
        }
    }

    @Test("contains matches on the place, driving Add to Sidebar being disabled")
    func contains() {
        withStore { store, _ in
            store.add(favorite("raw/"))
            #expect(store.contains(account: .azure("acct"), location: BrowserLocation(container: "data", prefix: "raw/")))
            #expect(!store.contains(account: .azure("acct"), location: BrowserLocation(container: "data", prefix: "cooked/")))
            #expect(!store.contains(account: .azure("other"), location: BrowserLocation(container: "data", prefix: "raw/")))
        }
    }

    @Test("Removing takes out only the one asked for")
    func remove() {
        withStore { store, _ in
            let first = favorite("a/")
            store.add(first)
            store.add(favorite("b/"))
            store.remove(id: first.id)
            #expect(store.favorites.map(\.prefix) == ["b/"])
        }
    }

    @Test("Renaming to blank restores the folder's own name")
    func rename() {
        withStore { store, _ in
            let item = favorite("raw/")
            store.add(item)
            store.rename(id: item.id, to: "Landing zone")
            #expect(store.favorites[0].displayName == "Landing zone")
            store.rename(id: item.id, to: "   ")
            #expect(store.favorites[0].customName == nil)
            #expect(store.favorites[0].displayName == "raw")
        }
    }

    @Test("Moving down accounts for the row leaving its old slot")
    func moveDown() {
        withStore { store, _ in
            let a = favorite("a/"), b = favorite("b/"), c = favorite("c/")
            [a, b, c].forEach { store.add($0) }
            // Dropping A at index 2 of [A, B, C] means "between B and C".
            store.move(id: a.id, to: 2)
            #expect(store.favorites.map(\.prefix) == ["b/", "a/", "c/"])
        }
    }

    @Test("Moving up inserts at the index given")
    func moveUp() {
        withStore { store, _ in
            let a = favorite("a/"), b = favorite("b/"), c = favorite("c/")
            [a, b, c].forEach { store.add($0) }
            store.move(id: c.id, to: 0)
            #expect(store.favorites.map(\.prefix) == ["c/", "a/", "b/"])
        }
    }

    @Test("Dropping a row onto itself changes nothing")
    func moveNoOp() {
        withStore { store, _ in
            let a = favorite("a/"), b = favorite("b/")
            [a, b].forEach { store.add($0) }
            store.move(id: a.id, to: 0)
            store.move(id: a.id, to: 1)
            #expect(store.favorites.map(\.prefix) == ["a/", "b/"])
        }
    }

    @Test("Moving to the end works")
    func moveToEnd() {
        withStore { store, _ in
            let a = favorite("a/"), b = favorite("b/"), c = favorite("c/")
            [a, b, c].forEach { store.add($0) }
            store.move(id: b.id, to: 3)
            #expect(store.favorites.map(\.prefix) == ["a/", "c/", "b/"])
        }
    }

    @Test("Inserting at an index puts it there, for a drop between rows")
    func addAtIndex() {
        withStore { store, _ in
            store.add(favorite("a/"))
            store.add(favorite("c/"))
            store.add(favorite("b/"), at: 1)
            #expect(store.favorites.map(\.prefix) == ["a/", "b/", "c/"])
        }
    }

    @Test("Favorites and their order survive a relaunch")
    func persists() {
        withStore { store, defaults in
            store.add(favorite("a/"))
            let b = favorite("b/")
            store.add(b)
            store.rename(id: b.id, to: "Bee")
            store.move(id: b.id, to: 0)

            let reopened = FavoritesStore(defaults: defaults)
            #expect(reopened.favorites.map(\.displayName) == ["Bee", "a"])
        }
    }
}

@MainActor
@Suite("Location drag payload")
struct LocationDragTests {

    @Test("A dragged place round-trips through the pasteboard")
    func roundTrip() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("com.kizersolutions.strata.tests.drag"))
        board.clearContents()
        let drag = LocationDrag(
            account: .azure("acct"),
            location: BrowserLocation(container: "data", prefix: "raw/2026/")
        )
        #expect(board.writeObjects([drag.pasteboardItem()]))

        let decoded = try #require(LocationDrag.read(from: board))
        #expect(decoded == drag)
        #expect(decoded.location == BrowserLocation(container: "data", prefix: "raw/2026/"))
        #expect(decoded.favoriteID == nil)
        board.clearContents()
    }

    @Test("A drag from an existing favorite carries its id, so a drop reorders")
    func carriesFavoriteID() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("com.kizersolutions.strata.tests.drag2"))
        board.clearContents()
        let id = UUID()
        let drag = LocationDrag(
            account: .azure("acct"),
            location: BrowserLocation(container: "data", prefix: ""),
            favoriteID: id
        )
        #expect(board.writeObjects([drag.pasteboardItem()]))
        #expect(try #require(LocationDrag.read(from: board)).favoriteID == id)
        board.clearContents()
    }

    @Test("A pasteboard with no location drag yields nothing")
    func emptyPasteboard() {
        let board = NSPasteboard(name: NSPasteboard.Name("com.kizersolutions.strata.tests.drag3"))
        board.clearContents()
        board.setString("just text", forType: .string)
        #expect(LocationDrag.read(from: board) == nil)
        board.clearContents()
    }
}
