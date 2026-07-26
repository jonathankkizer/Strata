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

    /// Standard macOS settings-window content width. Height is measured from the
    /// content rather than guessed, so the window hugs the panes.
    private static let windowWidth: CGFloat = 520

    /// Where a regular NSButton checkbox's *title* starts, measured from the
    /// button's leading edge. Captions line up with the title, not with the box —
    /// the System Settings / Safari convention.
    private static let captionIndent: CGFloat = 20

    /// Pop-up listing the current download folder plus an "Other…" escape, the same
    /// shape as Safari's "File download location".
    private let downloadLocationPopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    /// Wrapping captions can't resolve their own height until something tells them
    /// how wide they are; `viewDidLayout` feeds them their real width.
    private var captions: [NSTextField] = []

    override func loadView() {
        let root = NSView()
        let boxes = [makeStartupBox(), makeUploadsBox(), makeDownloadsBox()]

        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.windowWidth),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ] + boxes.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        view = root

        updatePreferredContentSize()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if syncCaptionWrapWidths() {
            updatePreferredContentSize()
        }
    }

    /// Returns true when a width actually changed, so callers can avoid an
    /// unnecessary second layout pass (and the loop that would come with it).
    @discardableResult
    private func syncCaptionWrapWidths() -> Bool {
        var changed = false
        for caption in captions {
            let width = caption.frame.width
            guard width > 0, abs(caption.preferredMaxLayoutWidth - width) > 0.5 else { continue }
            caption.preferredMaxLayoutWidth = width
            changed = true
        }
        return changed
    }

    private func updatePreferredContentSize() {
        view.layoutSubtreeIfNeeded()
        syncCaptionWrapWidths()
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.windowWidth, height: view.fittingSize.height)
    }

    // MARK: - Startup

    private func makeStartupBox() -> NSBox {
        let checkbox = NSButton(
            checkboxWithTitle: "Reconnect to the last account on launch",
            target: self,
            action: #selector(reconnectOnLaunchChanged(_:))
        )
        checkbox.state = StrataDefaults.reconnectOnLaunch ? .on : .off

        return makeBox(titled: "Startup", content: [
            setting(checkbox, caption:
                "Reopens the account and folder you were last browsing. Credentials are "
                + "never stored — Strata asks the az CLI for a fresh token each time."
            ),
        ])
    }

    // MARK: - Uploads

    private func makeUploadsBox() -> NSBox {
        let checkbox = NSButton(
            checkboxWithTitle: "Ask before uploading",
            target: self,
            action: #selector(askBeforeUploadingChanged(_:))
        )
        checkbox.state = StrataDefaults.askBeforeUploading ? .on : .off

        return makeBox(titled: "Uploads", content: [
            setting(checkbox, caption:
                "Shows each file's predicted Event Grid event before the upload starts. "
                + "When off, uploads begin immediately and predictions appear in the Transfers list."
            ),
        ])
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

        return makeBox(titled: "Downloads", content: [
            locationRow,
            setting(askCheckbox, caption:
                "File ▸ Download saves here without asking. Download To… always asks, "
                + "and dragging a blob to the Finder downloads it wherever you drop it."
            ),
        ])
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

    /// A control with its explanatory caption beneath it. The caption is indented to
    /// the control's title and pinned to the trailing edge, so it wraps to the real
    /// available width instead of a hardcoded one that left a lopsided right margin.
    private func setting(_ control: NSView, caption text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        captions.append(label)

        control.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(control)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            control.topAnchor.constraint(equalTo: container.topAnchor),
            control.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            control.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            // 4pt binds the caption to its control; the 10pt between settings in
            // `makeBox` then reads as the larger gap, which is what makes the
            // grouping legible.
            label.topAnchor.constraint(equalTo: control.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.captionIndent),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// Grouped box, System Settings style, so each setting reads as intentional.
    private func makeBox(titled title: String, content: [NSView]) -> NSBox {
        let group = NSStackView(views: content)
        group.orientation = .vertical
        // `.width` (not `.leading`) so each row spans the box and the wrapping
        // captions inside them get a width to wrap against.
        group.alignment = .width
        group.spacing = 10
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

    @objc private func reconnectOnLaunchChanged(_ sender: NSButton) {
        StrataDefaults.reconnectOnLaunch = sender.state == .on
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
