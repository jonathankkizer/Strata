import AppKit

extension NSPasteboard.PasteboardType {
    /// A place inside Strata, dragged to the Favorites section. Private to the app —
    /// dragging a folder to the Finder is meaningless until recursive download
    /// exists, and this type deliberately gives other apps nothing to accept.
    static let strataLocation = NSPasteboard.PasteboardType("com.kizersolutions.strata.location")
}

/// The payload behind a location drag: which place, and — when the drag started from
/// an existing favorite — which favorite, so a drop inside the Favorites section
/// reorders instead of adding a duplicate.
struct LocationDrag: Codable, Sendable, Equatable {
    var account: String
    var container: String
    var prefix: String
    var favoriteID: UUID?

    init(account: String, location: BrowserLocation, favoriteID: UUID? = nil) {
        self.account = account
        self.container = location.container
        self.prefix = location.prefix
        self.favoriteID = favoriteID
    }

    var location: BrowserLocation {
        BrowserLocation(container: container, prefix: prefix)
    }

    // MARK: - Pasteboard

    /// A pasteboard item carrying just this drag. Folders offer no other
    /// representation, so the drag is only accepted inside Strata.
    func pasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        write(to: item)
        return item
    }

    func write(to item: NSPasteboardItem) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        item.setData(data, forType: .strataLocation)
    }

    /// Reads the first location drag on a pasteboard, if there is one.
    static func read(from pasteboard: NSPasteboard) -> LocationDrag? {
        guard let data = pasteboard.data(forType: .strataLocation) else { return nil }
        return try? JSONDecoder().decode(LocationDrag.self, from: data)
    }
}
