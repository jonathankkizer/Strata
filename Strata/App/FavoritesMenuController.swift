import AppKit

/// Keeps the Go menu's list of saved places current.
///
/// Favorites change while the app runs, so the section is rebuilt in
/// `menuNeedsUpdate` — the standard way to drive a dynamic Mac menu — rather than
/// baked in when the menu bar is built at launch. Listed inline in Go, the way the
/// Finder lists its locations, so they carry keyboard shortcuts.
@MainActor
final class FavoritesMenuController: NSObject, NSMenuDelegate {

    /// Marks the items this controller owns, so a rebuild can remove exactly its own
    /// entries and leave the fixed commands alone.
    private static let tag = 7701

    /// The first nine get ⌃⌘1…⌘9. ⌘1/⌘2 are the view modes and ⌃⌥⌘1–5 are the sort
    /// fields, so this row of the keyboard is free.
    private static let shortcutLimit = 9

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.filter { $0.tag == Self.tag }.forEach(menu.removeItem)

        let favorites = FavoritesStore.shared.favorites
        guard !favorites.isEmpty else { return }

        // Appended after the fixed commands, with a separator of our own so removing
        // every favorite doesn't leave a stray divider behind.
        var index = menu.items.count
        let separator = NSMenuItem.separator()
        separator.tag = Self.tag
        menu.insertItem(separator, at: index)
        index += 1

        for (position, favorite) in favorites.enumerated() {
            let item = NSMenuItem(
                title: favorite.displayName,
                action: #selector(BrowserSplitViewController.goToFavoriteMenuItem(_:)),
                keyEquivalent: position < Self.shortcutLimit ? String(position + 1) : ""
            )
            if position < Self.shortcutLimit {
                item.keyEquivalentModifierMask = [.command, .control]
            }
            item.tag = Self.tag
            item.representedObject = favorite.id
            item.target = nil   // routed via the responder chain to the key window
            item.toolTip = "\(favorite.account) — \(favorite.location.path)"
            menu.insertItem(item, at: index)
            index += 1
        }
    }
}
