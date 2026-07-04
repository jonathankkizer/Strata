import AppKit

/// The main browser window. Programmatic NSWindow with autosaved frame (state
/// restoration), native tabbing, a unified toolbar, and a source-list + object-list
/// split view as its content.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {

    private let splitViewController = BrowserSplitViewController()

    private enum ToolbarID {
        static let connect = NSToolbarItem.Identifier("connect")
        static let refresh = NSToolbarItem.Identifier("refresh")
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Strata"
        window.isRestorable = true
        window.setFrameAutosaveName("StrataBrowserWindow")
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "StrataBrowser"
        window.minSize = NSSize(width: 720, height: 480)

        self.init(window: window)

        window.delegate = self
        window.contentViewController = splitViewController
        configureToolbar(for: window)
        window.center()
    }

    private func configureToolbar(for window: NSWindow) {
        let toolbar = NSToolbar(identifier: "StrataBrowserToolbar.v1")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, ToolbarID.connect, ToolbarID.refresh, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, ToolbarID.connect, ToolbarID.refresh, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: .sidebarTrackingSeparator,
                splitView: splitViewController.splitView,
                dividerIndex: 0
            )
        case ToolbarID.connect:
            return toolbarButton(
                id: itemIdentifier,
                label: "Connect",
                symbol: "externaldrive.badge.plus",
                action: #selector(BrowserSplitViewController.connectAzureStorageAccount(_:))
            )
        case ToolbarID.refresh:
            return toolbarButton(
                id: itemIdentifier,
                label: "Refresh",
                symbol: "arrow.clockwise",
                action: #selector(BrowserSplitViewController.refreshListing(_:))
            )
        default:
            return nil
        }
    }

    private func toolbarButton(id: NSToolbarItem.Identifier, label: String, symbol: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.isBordered = true
        item.target = splitViewController
        item.action = action
        return item
    }
}
