import AppKit

/// Builds the "Sort By" menu shared by the View menu and the browse context menus,
/// so the sort options match Finder everywhere. Items route to
/// `BrowserSplitViewController.sortBy(_:)` via the responder chain and carry their
/// `SortKey` in `representedObject`.
enum SortMenu {

    /// Menu order (mirrors Finder's Sort By ordering for the fields we have).
    static let order: [SortKey] = [.name, .kind, .dateModified, .size, .tier]

    /// A "Sort By" submenu. With `shortcuts`, items get ⌃⌥⌘1…5 (compact numbering,
    /// matching the app's ⌘1/⌘2 view switch).
    static func makeMenu(shortcuts: Bool) -> NSMenu {
        let menu = NSMenu(title: "Sort By")
        menu.autoenablesItems = true   // so items validate (checkmark on the current key)
        for (index, key) in order.enumerated() {
            let item = NSMenuItem(
                title: key.displayName,
                action: #selector(BrowserSplitViewController.sortBy(_:)),
                keyEquivalent: shortcuts ? "\(index + 1)" : ""
            )
            if shortcuts { item.keyEquivalentModifierMask = [.control, .option, .command] }
            item.representedObject = key
            menu.addItem(item)
        }
        return menu
    }

    /// A "Sort By" item wrapping the submenu, for insertion into a context menu.
    static func makeItem(shortcuts: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        item.submenu = makeMenu(shortcuts: shortcuts)
        return item
    }
}
