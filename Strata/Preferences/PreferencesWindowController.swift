import AppKit

/// Classic Mac preferences window: an NSToolbar of icon+label items, one per
/// pane, with the window animating its size when panes are added. Explicitly
/// NOT the SwiftUI Settings scene. Currently hosts the General pane; add a
/// second pane by appending to `panes` and calling `switchPane(_:)`.
@MainActor
final class PreferencesWindowController: NSWindowController {

    // MARK: - Pane registry

    private struct Pane {
        let identifier: String
        let label: String
        let symbolName: String
        let viewController: NSViewController
    }

    private var panes: [String: Pane] = [:]
    private var currentPaneIdentifier: String = ""

    // MARK: - Init

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 140),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isRestorable = true
        window.setFrameAutosaveName("StrataPreferencesWindow")
        self.init(window: window)

        // Register panes
        let generalPane = Pane(
            identifier: "general",
            label: "General",
            symbolName: "gearshape",
            viewController: GeneralPreferencesViewController()
        )
        panes[generalPane.identifier] = generalPane

        // Configure toolbar
        let toolbar = NSToolbar(identifier: "StrataPreferencesToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbarStyle = .preference
        window.toolbar = toolbar

        // Select the General pane
        switchPane("general")
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier("general")

        if !window.setFrameUsingName("StrataPreferencesWindow") { window.center() }
    }

    // MARK: - Pane switching

    func switchPane(_ identifier: String) {
        guard let pane = panes[identifier] else { return }
        currentPaneIdentifier = identifier
        window?.contentViewController = pane.viewController
        window?.title = pane.label
    }
}

// MARK: - NSToolbarDelegate

extension PreferencesWindowController: NSToolbarDelegate {

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        panes.keys.sorted().map { NSToolbarItem.Identifier($0) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        panes.keys.sorted().map { NSToolbarItem.Identifier($0) }
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        panes.keys.sorted().map { NSToolbarItem.Identifier($0) }
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = panes[itemIdentifier.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.label
        item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.label)
        item.target = self
        item.action = #selector(toolbarItemSelected(_:))
        return item
    }

    @objc private func toolbarItemSelected(_ sender: NSToolbarItem) {
        switchPane(sender.itemIdentifier.rawValue)
    }
}

// MARK: - General pane

private final class GeneralPreferencesViewController: NSViewController {

    override func loadView() {
        // Checkbox
        let checkbox = NSButton(
            checkboxWithTitle: "Ask before uploading",
            target: self,
            action: #selector(askBeforeUploadingChanged(_:))
        )
        checkbox.state = StrataDefaults.askBeforeUploading ? .on : .off

        // Description label
        let description = NSTextField(wrappingLabelWithString:
            "Shows each file's predicted Event Grid event before the upload starts. " +
            "When off, uploads begin immediately and predictions appear in the Transfers list."
        )
        description.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        description.textColor = .secondaryLabelColor
        // A wrapping label's intrinsic width is the full single-line text; cap it
        // so the window (sized from the content's fitting size) stays compact.
        description.preferredMaxLayoutWidth = 360
        description.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true

        // Stack: checkbox on top, description indented below
        let innerStack = NSStackView(views: [checkbox, description])
        innerStack.orientation = .vertical
        innerStack.alignment = .leading
        innerStack.spacing = 6

        let outerStack = NSStackView(views: [innerStack])
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        self.view = outerStack
    }

    @objc private func askBeforeUploadingChanged(_ sender: NSButton) {
        StrataDefaults.askBeforeUploading = sender.state == .on
    }
}
