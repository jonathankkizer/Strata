import AppKit

/// Classic Mac preferences window: an NSToolbar of icon+label items, one per pane,
/// with the window sizing itself to the selected pane's content. Explicitly NOT the
/// SwiftUI Settings scene. Currently hosts the General pane; add a second pane by
/// appending to `panes`.
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // No frame autosave: the window sizes to the selected pane's content each
        // time, so a stale saved frame can't clamp it too small.
        window.isRestorable = false
        self.init(window: window)

        let generalPane = Pane(
            identifier: "general",
            label: "General",
            symbolName: "gearshape",
            viewController: GeneralPreferencesViewController()
        )
        panes[generalPane.identifier] = generalPane

        let toolbar = NSToolbar(identifier: "StrataPreferencesToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbarStyle = .preference
        window.toolbar = toolbar

        // Restore the last-selected pane, falling back to General if the saved one
        // no longer exists.
        let initialPane = StrataDefaults.preferencesPane.flatMap { panes[$0] != nil ? $0 : nil } ?? "general"
        switchPane(initialPane)
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(initialPane)
        window.center()
    }

    // MARK: - Pane switching

    func switchPane(_ identifier: String) {
        guard let pane = panes[identifier], let window else { return }
        currentPaneIdentifier = identifier
        StrataDefaults.preferencesPane = identifier
        window.title = pane.label
        window.contentViewController = pane.viewController
        // Size the window to the pane's content (contentViewController assignment
        // usually does this; set it explicitly so it's reliable).
        let size = pane.viewController.preferredContentSize
        if size.width > 0, size.height > 0 {
            window.setContentSize(size)
        }
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
        let checkbox = NSButton(
            checkboxWithTitle: "Ask before uploading",
            target: self,
            action: #selector(askBeforeUploadingChanged(_:))
        )
        checkbox.state = StrataDefaults.askBeforeUploading ? .on : .off
        checkbox.translatesAutoresizingMaskIntoConstraints = false

        let description = NSTextField(wrappingLabelWithString:
            "Shows each file's predicted Event Grid event before the upload starts. " +
            "When off, uploads begin immediately and predictions appear in the Transfers list."
        )
        description.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        description.textColor = .secondaryLabelColor
        description.translatesAutoresizingMaskIntoConstraints = false
        description.preferredMaxLayoutWidth = 430
        description.widthAnchor.constraint(equalToConstant: 430).isActive = true

        let group = NSStackView(views: [checkbox, description])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 6
        group.translatesAutoresizingMaskIntoConstraints = false

        // Grouped box, System Settings style, so the setting reads as intentional.
        let box = NSBox()
        box.title = "Uploads"
        box.translatesAutoresizingMaskIntoConstraints = false
        let boxContent = box.contentView ?? NSView()
        boxContent.addSubview(group)
        NSLayoutConstraint.activate([
            group.topAnchor.constraint(equalTo: boxContent.topAnchor, constant: 6),
            group.bottomAnchor.constraint(equalTo: boxContent.bottomAnchor, constant: -10),
            group.leadingAnchor.constraint(equalTo: boxContent.leadingAnchor, constant: 8),
            group.trailingAnchor.constraint(equalTo: boxContent.trailingAnchor, constant: -8),
        ])

        let root = NSView()
        root.addSubview(box)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            box.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            box.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            box.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        view = root

        preferredContentSize = NSSize(width: 520, height: 180)
    }

    @objc private func askBeforeUploadingChanged(_ sender: NSButton) {
        StrataDefaults.askBeforeUploading = sender.state == .on
    }
}
