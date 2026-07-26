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

    private let contentWidth: CGFloat = 430

    /// Pop-up listing the current download folder plus an "Other…" escape, the same
    /// shape as Safari's "File download location".
    private let downloadLocationPopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    override func loadView() {
        let root = NSView()
        let uploads = makeUploadsBox()
        let downloads = makeDownloadsBox()

        let stack = NSStackView(views: [uploads, downloads])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            uploads.widthAnchor.constraint(equalTo: stack.widthAnchor),
            downloads.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root

        preferredContentSize = NSSize(width: 520, height: 330)
    }

    // MARK: - Uploads

    private func makeUploadsBox() -> NSBox {
        let checkbox = NSButton(
            checkboxWithTitle: "Ask before uploading",
            target: self,
            action: #selector(askBeforeUploadingChanged(_:))
        )
        checkbox.state = StrataDefaults.askBeforeUploading ? .on : .off

        let description = explanatoryLabel(
            "Shows each file's predicted Event Grid event before the upload starts. " +
            "When off, uploads begin immediately and predictions appear in the Transfers list."
        )
        return makeBox(titled: "Uploads", content: [checkbox, description])
    }

    // MARK: - Downloads

    private func makeDownloadsBox() -> NSBox {
        let locationLabel = NSTextField(labelWithString: "Save downloaded files to:")

        downloadLocationPopUp.target = self
        downloadLocationPopUp.action = #selector(downloadLocationChanged(_:))
        rebuildDownloadLocationMenu()

        let locationRow = NSStackView(views: [locationLabel, downloadLocationPopUp])
        locationRow.orientation = .horizontal
        locationRow.spacing = 8
        locationRow.alignment = .firstBaseline

        let askCheckbox = NSButton(
            checkboxWithTitle: "Ask for each download",
            target: self,
            action: #selector(askWhereToSaveChanged(_:))
        )
        askCheckbox.state = StrataDefaults.askWhereToSaveDownloads ? .on : .off

        let description = explanatoryLabel(
            "File ▸ Download saves here without asking. Download To… always asks, " +
            "and dragging a blob to the Finder downloads it wherever you drop it."
        )
        return makeBox(titled: "Downloads", content: [locationRow, askCheckbox, description])
    }

    /// Shows the folder with its real Finder icon, plus the "Other…" chooser.
    private func rebuildDownloadLocationMenu() {
        let directory = StrataDefaults.downloadDirectory
        let menu = NSMenu()

        let current = NSMenuItem(title: directory.lastPathComponent, action: nil, keyEquivalent: "")
        let icon = NSWorkspace.shared.icon(forFile: directory.path)
        icon.size = NSSize(width: 16, height: 16)
        current.image = icon
        current.representedObject = directory
        menu.addItem(current)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Other\u{2026}", action: nil, keyEquivalent: "")

        downloadLocationPopUp.menu = menu
        downloadLocationPopUp.selectItem(at: 0)
    }

    // MARK: - Shared chrome

    private func explanatoryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = contentWidth
        label.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return label
    }

    /// Grouped box, System Settings style, so each setting reads as intentional.
    private func makeBox(titled title: String, content: [NSView]) -> NSBox {
        let group = NSStackView(views: content)
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 6
        group.translatesAutoresizingMaskIntoConstraints = false

        let box = NSBox()
        box.title = title
        box.translatesAutoresizingMaskIntoConstraints = false
        let boxContent = box.contentView ?? NSView()
        boxContent.addSubview(group)
        NSLayoutConstraint.activate([
            group.topAnchor.constraint(equalTo: boxContent.topAnchor, constant: 6),
            group.bottomAnchor.constraint(equalTo: boxContent.bottomAnchor, constant: -10),
            group.leadingAnchor.constraint(equalTo: boxContent.leadingAnchor, constant: 8),
            group.trailingAnchor.constraint(equalTo: boxContent.trailingAnchor, constant: -8),
        ])
        return box
    }

    // MARK: - Actions

    @objc private func askBeforeUploadingChanged(_ sender: NSButton) {
        StrataDefaults.askBeforeUploading = sender.state == .on
    }

    @objc private func askWhereToSaveChanged(_ sender: NSButton) {
        StrataDefaults.askWhereToSaveDownloads = sender.state == .on
    }

    @objc private func downloadLocationChanged(_ sender: NSPopUpButton) {
        // Index 0 is the current folder; the last item is "Other…".
        guard sender.indexOfSelectedItem != 0 else { return }
        guard let window = view.window else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where downloaded files are saved"
        panel.directoryURL = StrataDefaults.downloadDirectory
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url {
                StrataDefaults.downloadDirectory = url
            }
            // Rebuild either way, so cancelling restores the previous selection.
            self?.rebuildDownloadLocationMenu()
        }
    }
}
