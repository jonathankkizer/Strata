import AppKit

/// The main browser window. Programmatic NSWindow with autosaved frame (state
/// restoration), native tabbing, a unified toolbar, and a source-list + object-list
/// split view as its content.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {

    var onWindowClose: (() -> Void)?

    private let splitViewController = BrowserSplitViewController()
    private let transfersButton = TransfersToolbarButton(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
    private lazy var transfersPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = TransfersPopoverViewController()
        return popover
    }()

    private enum ToolbarID {
        static let connect = NSToolbarItem.Identifier("connect")
        static let refresh = NSToolbarItem.Identifier("refresh")
        static let upload = NSToolbarItem.Identifier("upload")
        static let inspector = NSToolbarItem.Identifier("inspector")
        static let transfers = NSToolbarItem.Identifier("transfers")
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
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "StrataBrowser"
        window.minSize = NSSize(width: 720, height: 480)

        self.init(window: window)

        window.delegate = self
        window.contentViewController = splitViewController
        configureToolbar(for: window)
        observeTransferQueue()
        if !window.setFrameUsingName("StrataBrowserWindow") { window.center() }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onWindowClose?()
    }

    // MARK: - Transfer queue

    private func observeTransferQueue() {
        transfersButton.target = self
        transfersButton.action = #selector(toggleTransfers(_:))

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(updateTransfersButton), name: .transferQueueDidChange, object: nil)
        center.addObserver(self, selector: #selector(updateTransfersButton), name: .transferQueueProgress, object: nil)
        center.addObserver(self, selector: #selector(revealTransfers), name: .transferQueueDidEnqueue, object: nil)
        updateTransfersButton()
    }

    @objc private func updateTransfersButton() {
        let queue = TransferQueue.shared
        transfersButton.update(active: queue.hasActive, fraction: queue.aggregateFraction)
    }

    @objc private func toggleTransfers(_ sender: Any?) {
        if transfersPopover.isShown {
            transfersPopover.performClose(sender)
        } else {
            transfersPopover.show(relativeTo: transfersButton.bounds, of: transfersButton, preferredEdge: .maxY)
        }
    }

    /// Reveal the queue when the key window's browser enqueues uploads.
    @objc private func revealTransfers() {
        guard window?.isKeyWindow == true, !transfersPopover.isShown else { return }
        transfersPopover.show(relativeTo: transfersButton.bounds, of: transfersButton, preferredEdge: .maxY)
    }

    private func configureToolbar(for window: NSWindow) {
        let toolbar = NSToolbar(identifier: "StrataBrowserToolbar.v1")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, ToolbarID.connect, ToolbarID.upload, ToolbarID.refresh, .flexibleSpace, ToolbarID.transfers, ToolbarID.inspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, ToolbarID.connect, ToolbarID.upload, ToolbarID.refresh, ToolbarID.transfers, ToolbarID.inspector, .flexibleSpace, .space]
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
        case ToolbarID.upload:
            return toolbarButton(
                id: itemIdentifier,
                label: "Upload",
                symbol: "arrow.up.doc",
                action: #selector(BrowserSplitViewController.uploadFiles(_:))
            )
        case ToolbarID.inspector:
            return toolbarButton(
                id: itemIdentifier,
                label: "Inspector",
                symbol: "sidebar.trailing",
                action: #selector(BrowserSplitViewController.toggleObjectInspector(_:))
            )
        case ToolbarID.transfers:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Transfers"
            item.toolTip = "Transfers"
            item.view = transfersButton
            let menuItem = NSMenuItem(title: "Transfers", action: #selector(toggleTransfers(_:)), keyEquivalent: "")
            menuItem.target = self
            item.menuFormRepresentation = menuItem
            return item
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
