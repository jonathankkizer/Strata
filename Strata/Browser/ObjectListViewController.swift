import AppKit

/// The main browse surface: a clickable path bar, a sortable table of folders and
/// blobs for the current location, and loading/empty/error states. Owns its own
/// async loading against the provider.
@MainActor
final class ObjectListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    var provider: (any StorageProvider)?

    /// Fired when the table's selection changes (single selection, or nil).
    var onSelectionChange: ((StorageObject?) -> Void)?

    /// Fired when files or folders are dropped from Finder onto the table; folders are
    /// expanded recursively by the caller.
    var onDropFiles: (([URL]) -> Void)?

    var location: BrowserLocation? {
        didSet {
            guard location != oldValue else { return }
            updatePathBar()
            reload()
        }
    }

    private enum Column: String {
        case name, size, tier, modified, kind
    }

    private let pathControl = NSPathControl()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let spinner = NSProgressIndicator()

    // Empty-state view and its configurable subviews.
    private let emptyStateView = NSStackView()
    private let emptyStateImageView = NSImageView()
    private let emptyStateTitleLabel = NSTextField(labelWithString: "")
    private let emptyStateSubtitleLabel = NSTextField(labelWithString: "")
    private let emptyStateButton = NSButton(title: "", target: nil, action: nil)

    private var items: [StorageObject] = []
    private var loadToken = 0
    private var pendingSelectKey: String?

    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        configurePathControl()
        configureTable()
        configureEmptyState()
        configureSpinner()

        view.addSubview(pathControl)
        view.addSubview(scrollView)
        view.addSubview(emptyStateView)
        view.addSubview(spinner)

        pathControl.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        // scrollView and emptyStateView occupy the same region below the path bar.
        NSLayoutConstraint.activate([
            // Pin below the toolbar (safe area), not the window top, so the path bar
            // doesn't sit behind the translucent titlebar and ghost through it.
            pathControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            pathControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            pathControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: pathControl.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 20),
            emptyStateView.widthAnchor.constraint(lessThanOrEqualToConstant: 320),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        showEmptyState(
            symbol: "externaldrive.badge.questionmark",
            title: "No Account Connected",
            subtitle: "Connect to an Azure storage account to browse your containers and blobs.",
            actionTitle: "Connect\u{2026}",
            action: #selector(BrowserSplitViewController.connectAzureStorageAccount(_:))
        )
    }

    // MARK: - Configuration

    private func configurePathControl() {
        pathControl.pathStyle = .standard
        pathControl.target = self
        pathControl.action = #selector(pathControlClicked(_:))
        pathControl.isEnabled = true
        pathControl.focusRingType = .none
    }

    private func configureTable() {
        addColumn(.name, title: "Name", width: 320, minWidth: 160, alignment: .left)
        addColumn(.size, title: "Size", width: 90, minWidth: 60, alignment: .right)
        addColumn(.tier, title: "Tier", width: 70, minWidth: 50, alignment: .left)
        addColumn(.modified, title: "Date Modified", width: 170, minWidth: 120, alignment: .left)
        addColumn(.kind, title: "Content Type", width: 170, minWidth: 100, alignment: .left)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .inset
        tableView.rowSizeStyle = .default
        tableView.allowsMultipleSelection = true
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.target = self
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        // Drag-and-drop upload from Finder.
        tableView.registerForDraggedTypes([.fileURL])

        // Context menu (autoenablesItems = false — we manage Copy items explicitly).
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let copyNameItem = NSMenuItem(title: "Copy Name", action: #selector(copyName(_:)), keyEquivalent: "")
        copyNameItem.target = self
        let copyPathItem = NSMenuItem(title: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "")
        copyPathItem.target = self
        menu.addItem(copyNameItem)
        menu.addItem(copyPathItem)
        menu.addItem(.separator())
        let inspectorItem = NSMenuItem(title: "Show Inspector", action: #selector(BrowserSplitViewController.toggleObjectInspector(_:)), keyEquivalent: "")
        inspectorItem.target = nil   // routed via responder chain
        menu.addItem(inspectorItem)
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
    }

    private func addColumn(_ column: Column, title: String, width: CGFloat, minWidth: CGFloat, alignment: NSTextAlignment) {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
        tableColumn.title = title
        tableColumn.width = width
        tableColumn.minWidth = minWidth
        if column == .name || column == .size || column == .modified {
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
        }
        tableColumn.headerCell.alignment = alignment
        tableView.addTableColumn(tableColumn)
    }

    private func configureEmptyState() {
        emptyStateImageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .thin)
        emptyStateImageView.contentTintColor = .tertiaryLabelColor

        emptyStateTitleLabel.font = .boldSystemFont(ofSize: 15)
        emptyStateTitleLabel.textColor = .secondaryLabelColor
        emptyStateTitleLabel.alignment = .center
        emptyStateTitleLabel.lineBreakMode = .byWordWrapping
        emptyStateTitleLabel.maximumNumberOfLines = 0

        emptyStateSubtitleLabel.font = .systemFont(ofSize: 12)
        emptyStateSubtitleLabel.textColor = .tertiaryLabelColor
        emptyStateSubtitleLabel.alignment = .center
        emptyStateSubtitleLabel.lineBreakMode = .byWordWrapping
        emptyStateSubtitleLabel.maximumNumberOfLines = 0

        emptyStateButton.bezelStyle = .rounded
        emptyStateButton.controlSize = .regular

        emptyStateView.orientation = .vertical
        emptyStateView.alignment = .centerX
        emptyStateView.spacing = 8
        emptyStateView.addArrangedSubview(emptyStateImageView)
        emptyStateView.addArrangedSubview(emptyStateTitleLabel)
        emptyStateView.addArrangedSubview(emptyStateSubtitleLabel)
        emptyStateView.addArrangedSubview(emptyStateButton)
        // Spacing before button feels more Finder-like.
        emptyStateView.setCustomSpacing(14, after: emptyStateSubtitleLabel)

        emptyStateView.isHidden = true
    }

    private func configureSpinner() {
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
    }

    // MARK: - Empty state

    private func showEmptyState(
        symbol: String,
        title: String,
        subtitle: String?,
        actionTitle: String?,
        action: Selector?
    ) {
        emptyStateImageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        emptyStateTitleLabel.stringValue = title

        if let subtitle {
            emptyStateSubtitleLabel.stringValue = subtitle
            emptyStateSubtitleLabel.isHidden = false
        } else {
            emptyStateSubtitleLabel.stringValue = ""
            emptyStateSubtitleLabel.isHidden = true
        }

        if let actionTitle, let action {
            emptyStateButton.title = actionTitle
            emptyStateButton.target = nil   // routes up the responder chain
            emptyStateButton.action = action
            emptyStateButton.isHidden = false
        } else {
            emptyStateButton.isHidden = true
        }

        emptyStateView.isHidden = false
        scrollView.isHidden = true
    }

    private func hideEmptyState() {
        emptyStateView.isHidden = true
        scrollView.isHidden = false
    }

    // MARK: - Loading

    /// Reloads and, once loaded, selects the row with `key` (used after an upload).
    func reloadSelecting(key: String) {
        pendingSelectKey = key
        reload()
    }

    func reload() {
        guard let provider, let location else { return }

        loadToken += 1
        let token = loadToken
        hideEmptyState()
        items = []
        tableView.reloadData()
        spinner.startAnimation(nil)

        let container = StorageContainer(name: location.container)
        let prefix = location.prefix

        Task { @MainActor in
            let result: Result<[StorageObject], Error>
            do {
                result = .success(try await provider.listObjects(in: container, prefix: prefix))
            } catch {
                result = .failure(error)
            }

            guard token == self.loadToken else { return }   // a newer navigation superseded this load
            self.spinner.stopAnimation(nil)

            switch result {
            case .success(let objects):
                self.apply(objects, prefix: prefix)
            case .failure(let error):
                self.present(error)
            }
        }
    }

    private func apply(_ objects: [StorageObject], prefix: String) {
        items = objects
        sortItems()
        tableView.reloadData()
        if objects.isEmpty {
            showEmptyState(symbol: "tray", title: "This Folder Is Empty", subtitle: nil, actionTitle: nil, action: nil)
        } else {
            hideEmptyState()
        }

        if let key = pendingSelectKey, let index = items.firstIndex(where: { $0.key == key }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        }
        pendingSelectKey = nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        let object = (row >= 0 && row < items.count) ? items[row] : nil
        onSelectionChange?(object)
    }

    private func present(_ error: Error) {
        if case StorageProviderError.dataPlaneForbidden(let account) = error {
            showEmptyState(
                symbol: "exclamationmark.triangle",
                title: "Couldn\u{2019}t Load",
                subtitle: "Authenticated, but this identity lacks a \u{201c}Storage Blob Data\u{201d} role on \u{201c}\(account).\u{201d}\n\nGrant Storage Blob Data Reader or Contributor to browse blob data \u{2014} management roles (Owner/Contributor/Reader) don\u{2019}t grant data-plane access.",
                actionTitle: nil,
                action: nil
            )
        } else if case StorageProviderError.unauthorized = error {
            showEmptyState(
                symbol: "exclamationmark.triangle",
                title: "Couldn\u{2019}t Load",
                subtitle: "Not authorized. Your token may have expired \u{2014} try reconnecting.",
                actionTitle: nil,
                action: nil
            )
        } else {
            showEmptyState(
                symbol: "exclamationmark.triangle",
                title: "Couldn\u{2019}t Load",
                subtitle: "Couldn\u{2019}t load this location.\n\n\(error.localizedDescription)",
                actionTitle: nil,
                action: nil
            )
        }
    }

    // MARK: - Message state (external call sites — do not remove)

    /// Routes informational text from external callers (e.g. BrowserSplitViewController)
    /// through the empty-state view with a neutral symbol.
    func showMessage(_ text: String) {
        showEmptyState(
            symbol: "cloud",
            title: text,
            subtitle: nil,
            actionTitle: nil,
            action: nil
        )
    }

    // MARK: - Path bar

    private func updatePathBar() {
        guard let location else {
            pathControl.pathItems = []
            return
        }
        var pathItems: [NSPathControlItem] = []

        let root = NSPathControlItem()
        root.title = location.container
        root.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "Container")
        pathItems.append(root)

        for segment in location.segments {
            let item = NSPathControlItem()
            item.title = segment
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
            pathItems.append(item)
        }
        pathControl.pathItems = pathItems
    }

    @objc private func pathControlClicked(_ sender: NSPathControl) {
        guard let location, let clicked = sender.clickedPathItem,
              let index = sender.pathItems.firstIndex(of: clicked) else { return }
        // index 0 is the container root (empty prefix); index i keeps the first i segments.
        let newPrefix = index == 0 ? "" : location.segments[0..<index].map { $0 + "/" }.joined()
        guard newPrefix != location.prefix else { return }
        self.location = BrowserLocation(container: location.container, prefix: newPrefix)
    }

    @objc private func tableDoubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0, row < items.count, let location else { return }
        let item = items[row]
        guard item.isPrefix else { return }   // descending into folders only; blob open/preview comes later
        self.location = BrowserLocation(container: location.container, prefix: item.key)
    }

    // MARK: - Enclosing-folder navigation

    /// True when there is at least one folder segment above the current listing.
    var canNavigateUp: Bool { !(location?.prefix.isEmpty ?? true) }

    /// Moves to the parent folder. No-op at the container root.
    func navigateUp() {
        guard canNavigateUp, let location else { return }
        let segments = location.segments
        // Drop the last segment; re-join remaining ones as a slash-terminated prefix.
        let parentPrefix = segments.dropLast().map { $0 + "/" }.joined()
        self.location = BrowserLocation(container: location.container, prefix: parentPrefix)
    }

    // MARK: - Sorting

    private func sortItems() {
        let descriptor = tableView.sortDescriptors.first
        let key = descriptor?.key ?? Column.name.rawValue
        let ascending = descriptor?.ascending ?? true

        items.sort { lhs, rhs in
            // Folders always precede blobs regardless of sort field.
            if lhs.isPrefix != rhs.isPrefix { return lhs.isPrefix }
            let ordered: Bool
            switch key {
            case Column.size.rawValue:
                ordered = lhs.size < rhs.size
            case Column.modified.rawValue:
                ordered = (lhs.lastModified ?? .distantPast) < (rhs.lastModified ?? .distantPast)
            default:
                ordered = displayName(for: lhs).localizedStandardCompare(displayName(for: rhs)) == .orderedAscending
            }
            return ascending ? ordered : !ordered
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortItems()
        tableView.reloadData()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let item = items[row]

        switch column {
        case .name:
            let cell = nameCell()
            cell.textField?.stringValue = displayName(for: item)
            // Real macOS icons (the actual folder, a Markdown/CSV document icon…),
            // matching Finder rather than a tinted SF Symbol.
            cell.imageView?.image = BlobIcon.image(for: item)
            cell.imageView?.contentTintColor = nil
            return cell
        case .size:
            return textCell(item.isPrefix ? "\u{2014}" : byteFormatter.string(fromByteCount: item.size), alignment: .right)
        case .tier:
            return textCell(item.isPrefix ? "" : (item.storageClass ?? "\u{2014}"))
        case .modified:
            return textCell(item.lastModified.map { dateFormatter.string(from: $0) } ?? "")
        case .kind:
            return textCell(item.isPrefix ? "Folder" : (item.contentType ?? "\u{2014}"))
        }
    }

    private func displayName(for object: StorageObject) -> String {
        var key = object.key
        let prefix = location?.prefix ?? ""
        if !prefix.isEmpty, key.hasPrefix(prefix) { key.removeFirst(prefix.count) }
        if object.isPrefix, key.hasSuffix("/") { key.removeLast() }
        return key
    }

    // MARK: - Cell factories

    private func textCell(_ string: String, alignment: NSTextAlignment = .left) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("text")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false
            let view = NSTableCellView()
            view.identifier = id
            view.addSubview(textField)
            view.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            return view
        }()
        cell.textField?.stringValue = string
        cell.textField?.alignment = alignment
        cell.textField?.textColor = .labelColor
        return cell
    }

    private func nameCell() -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("name")
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            return reused
        }
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSTableCellView()
        cell.identifier = id
        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: - Drag-and-drop upload

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard location != nil,
              info.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let rawURLs = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !rawURLs.isEmpty else { return false }

        onDropFiles?(rawURLs)
        return true
    }

    // MARK: - Context menu actions

    @objc private func copyName(_ sender: Any?) {
        let names = selectedObjects().map { displayName(for: $0) }.joined(separator: "\n")
        guard !names.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names, forType: .string)
    }

    @objc private func copyPath(_ sender: Any?) {
        let keys = selectedObjects().map { $0.key }.joined(separator: "\n")
        guard !keys.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(keys, forType: .string)
    }

    /// Returns the objects for the current selection, preferring clicked row when
    /// it is outside the selection (handled by menuNeedsUpdate before this runs).
    private func selectedObjects() -> [StorageObject] {
        tableView.selectedRowIndexes.compactMap { idx in
            idx < items.count ? items[idx] : nil
        }
    }

    // MARK: - Edit ▸ Copy (Cmd+C)

    @objc func copy(_ sender: Any?) {
        copyPath(sender)
    }
}

// MARK: - NSMenuDelegate

extension ObjectListViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Follow Finder: if the clicked row is outside the selection, select it alone.
        let clicked = tableView.clickedRow
        if clicked >= 0, !tableView.selectedRowIndexes.contains(clicked) {
            tableView.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }

        // Determine whether there is anything to copy.
        let hasTarget = clicked >= 0 || tableView.selectedRow >= 0
        menu.items.forEach { item in
            if item.action == #selector(copyName(_:)) || item.action == #selector(copyPath(_:)) {
                item.isEnabled = hasTarget
            }
        }
    }
}

// MARK: - NSUserInterfaceValidations

extension ObjectListViewController: NSUserInterfaceValidations {
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return tableView.selectedRow >= 0
        }
        return true
    }
}
