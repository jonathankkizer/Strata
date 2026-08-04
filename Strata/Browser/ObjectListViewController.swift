import AppKit

/// The main browse surface: a clickable path bar, a sortable table of folders and
/// blobs for the current location, and loading/empty/error states. Owns its own
/// async loading against the provider.
@MainActor
final class ObjectListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    var provider: (any StorageProvider)?

    /// Fired when the table's selection changes, carrying the whole selection so the
    /// inspector can summarise a multi-selection rather than picking one row.
    var onSelectionChange: (([StorageObject]) -> Void)?

    /// Fired when files or folders are dropped from Finder onto the table; folders are
    /// expanded recursively by the caller.
    var onDropFiles: (([URL]) -> Void)?

    /// Fired when the browse location changes, so the shared path bar can update.
    var onLocationChange: ((BrowserLocation?) -> Void)?

    /// Fired when the user clicks a column header to change the sort, so the shared
    /// sort state (menus, columns view) can follow.
    var onSortChange: ((BrowseSort) -> Void)?

    /// True while a sort is being applied programmatically, to distinguish it from a
    /// user header click in `sortDescriptorsDidChange`.
    private var isApplyingSort = false

    var location: BrowserLocation? {
        didSet {
            guard location != oldValue else { return }
            onLocationChange?(location)
            reload()
        }
    }

    private enum Column: String {
        case name, size, tier, modified, kind
    }

    private let tableView = KeyNavTableView()
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

        configureTable()
        configureEmptyState()
        configureSpinner()

        view.addSubview(scrollView)
        view.addSubview(emptyStateView)
        view.addSubview(spinner)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        // scrollView and emptyStateView occupy the same region. Pin below the toolbar
        // (safe area) so content doesn't sit behind the translucent titlebar.
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
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
            subtitle: "Connect to a storage account to browse your buckets and objects.",
            actionTitle: "Connect\u{2026}",
            action: #selector(BrowserSplitViewController.connectStorageAccount(_:))
        )
    }

    // MARK: - Configuration

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
        tableView.onCommandDown = { [weak self] in self?.openSelection() }
        tableView.onSpace = { [weak self] in
            NSApp.sendAction(#selector(BrowserSplitViewController.toggleQuickLook(_:)), to: nil, from: self)
        }
        // Resize all columns to fit the pane width so content tracks the window
        // (and the inspector) instead of needing a horizontal scroll.
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        // Show the default sort indicator (Name, ascending).
        tableView.sortDescriptors = [NSSortDescriptor(key: Column.name.rawValue, ascending: true)]

        // Drag-and-drop upload from Finder.
        tableView.registerForDraggedTypes([.fileURL])
        // Blobs drag out to Finder as file promises; folders drag to the sidebar to
        // become favorites. Both are copies.
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)

        // Persist column widths, order, and visibility across launches.
        tableView.autosaveName = "StrataObjectList"
        tableView.autosaveTableColumns = true

        tableView.setAccessibilityLabel("Objects")

        // Context menu (autoenablesItems = false — we manage items explicitly).
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        // Download first: it is the primary verb for a blob, and Finder/Safari both
        // put the acting-on-content command above the copy commands.
        let quickLookItem = NSMenuItem(title: "Quick Look", action: #selector(BrowserSplitViewController.toggleQuickLook(_:)), keyEquivalent: "")
        quickLookItem.target = nil   // routed via the responder chain
        menu.addItem(quickLookItem)
        let downloadItem = NSMenuItem(title: "Download", action: #selector(BrowserSplitViewController.downloadSelection(_:)), keyEquivalent: "")
        downloadItem.target = nil   // routed via the responder chain
        let downloadToItem = NSMenuItem(title: "Download To\u{2026}", action: #selector(BrowserSplitViewController.downloadSelectionTo(_:)), keyEquivalent: "")
        downloadToItem.target = nil
        menu.addItem(downloadItem)
        menu.addItem(downloadToItem)
        menu.addItem(.separator())
        let copyNameItem = NSMenuItem(title: "Copy Name", action: #selector(copyName(_:)), keyEquivalent: "")
        copyNameItem.target = self
        let copyPathItem = NSMenuItem(title: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "")
        copyPathItem.target = self
        let copyURLItem = NSMenuItem(title: "Copy URL", action: #selector(copyURL(_:)), keyEquivalent: "")
        copyURLItem.target = self
        menu.addItem(copyNameItem)
        menu.addItem(copyPathItem)
        menu.addItem(copyURLItem)
        menu.addItem(.separator())
        let addToSidebarItem = NSMenuItem(title: "Add to Sidebar", action: #selector(BrowserSplitViewController.addToSidebar(_:)), keyEquivalent: "")
        addToSidebarItem.target = nil   // routed via the responder chain
        menu.addItem(addToSidebarItem)
        menu.addItem(.separator())
        menu.addItem(SortMenu.makeItem(shortcuts: false))
        menu.addItem(.separator())
        let inspectorItem = NSMenuItem(title: "Show Inspector", action: #selector(BrowserSplitViewController.toggleObjectInspector(_:)), keyEquivalent: "")
        inspectorItem.target = nil   // routed via responder chain
        menu.addItem(inspectorItem)
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        // Horizontal scroll so columns clipped by a narrower pane (e.g. when the
        // inspector opens) stay reachable rather than being lost.
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
    }

    private func addColumn(_ column: Column, title: String, width: CGFloat, minWidth: CGFloat, alignment: NSTextAlignment) {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
        tableColumn.title = title
        tableColumn.width = width
        tableColumn.minWidth = minWidth
        // Every column is sortable by clicking its header.
        tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
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
        onSelectionChange?(selectedObjects())
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

    @objc private func tableDoubleClicked(_ sender: NSTableView) {
        open(row: sender.clickedRow)
    }

    /// Open the selection — ⌘O / ⌘↓ / double-click. A folder descends into it; a blob
    /// downloads it, the way Transmit and Cyberduck treat "open" on a remote file.
    func openSelection() {
        open(row: tableView.selectedRow)
    }

    private func open(row: Int) {
        guard row >= 0, row < items.count, let location else { return }
        let item = items[row]
        if item.isPrefix {
            self.location = BrowserLocation(container: location.container, prefix: item.key)
        } else {
            NSApp.sendAction(#selector(BrowserSplitViewController.downloadSelection(_:)), to: nil, from: self)
        }
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

    /// The current sort, derived from the table's active sort descriptor.
    var currentSort: BrowseSort {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = SortKey(rawValue: descriptor.key ?? "") else { return BrowseSort() }
        return BrowseSort(key: key, ascending: descriptor.ascending)
    }

    /// Applies a sort programmatically (from a menu/context command).
    func applySort(_ sort: BrowseSort) {
        isApplyingSort = true
        tableView.sortDescriptors = [NSSortDescriptor(key: sort.key.rawValue, ascending: sort.ascending)]
        isApplyingSort = false
        sortItems()
        tableView.reloadData()
    }

    private func sortItems() {
        let sort = currentSort
        items.sort { sort.areInOrder($0, $1) }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortItems()
        tableView.reloadData()
        if !isApplyingSort { onSortChange?(currentSort) }
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

    // MARK: - Type-to-select

    /// Lets the user type a few characters to jump to a row, the way every native
    /// Mac list works. Without this the table has nothing to match against, because
    /// the cells are view-based.
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard row < items.count else { return nil }
        // Match on the name column only; matching a size or date would be noise.
        guard tableColumn == nil || tableColumn?.identifier.rawValue == Column.name.rawValue else { return nil }
        return displayName(for: items[row])
    }

    // MARK: - Drag out (file promises)

    /// Blobs drag out to Finder as file promises — the download happens on drop.
    /// Folders carry a location instead, which only Strata's own sidebar accepts:
    /// recursive prefix download isn't built, so promising the Finder a directory we
    /// can't produce would be worse than not offering the drag.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row < items.count, let location, let provider else { return nil }
        let item = items[row]
        guard !item.isPrefix else {
            return LocationDrag(
                account: provider.account,
                location: BrowserLocation(container: location.container, prefix: item.key)
            ).pasteboardItem()
        }
        return BlobFilePromiseProvider.make(
            for: item,
            in: StorageContainer(name: location.container),
            provider: provider
        )
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
        // Full path (container/key), matching the path bar and columns view.
        let paths = selectedObjects().map(fullPath(for:)).joined(separator: "\n")
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
    }

    @objc private func copyURL(_ sender: Any?) {
        let urls = selectedObjectURLs().map(\.absoluteString)
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, .URL], owner: nil)
        pasteboard.setString(urls.joined(separator: "\n"), forType: .string)
        if urls.count == 1 { pasteboard.setString(urls[0], forType: .URL) }
    }

    /// The container/key path for one object, matching the path bar's format.
    private func fullPath(for object: StorageObject) -> String {
        let container = location?.container ?? ""
        var key = object.key
        if key.hasSuffix("/") { key.removeLast() }
        return container.isEmpty ? key : "\(container)/\(key)"
    }

    /// Shareable URLs for the real blobs (not folders) in the current selection.
    private func selectedObjectURLs() -> [URL] {
        guard let location else { return [] }
        let container = StorageContainer(name: location.container)
        return selectedObjects().compactMap { object in
            object.isPrefix ? nil : provider?.objectURL(forKey: object.key, in: container)
        }
    }

    /// Returns the objects for the current selection, preferring clicked row when
    /// it is outside the selection (handled by menuNeedsUpdate before this runs).
    func selectedObjects() -> [StorageObject] {
        tableView.selectedRowIndexes.compactMap { idx in
            idx < items.count ? items[idx] : nil
        }
    }

    /// The real blobs (not folders) in the current selection — what Download acts on.
    var downloadableSelection: [StorageObject] {
        selectedObjects().filter { !$0.isPrefix }
    }

    /// A single selected folder — what "Add to Sidebar" saves. Ambiguous with several
    /// rows selected, so only one counts.
    var selectedFolder: StorageObject? {
        let selection = selectedObjects()
        guard selection.count == 1, let only = selection.first, only.isPrefix else { return nil }
        return only
    }

    /// The selected row's rect in screen coordinates, so Quick Look can zoom out of
    /// the row the way Finder does. Nil when nothing is selected or off screen.
    var selectedRowScreenRect: NSRect? {
        let row = tableView.selectedRow
        guard row >= 0, let window = tableView.window else { return nil }
        let rowRect = tableView.rect(ofRow: row)
        guard tableView.visibleRect.intersects(rowRect) else { return nil }
        return window.convertToScreen(tableView.convert(rowRect, to: nil))
    }

    /// Replays a key event into the table — used to keep arrow keys moving the
    /// selection while the Quick Look panel holds keyboard focus.
    func forwardKeyDown(_ event: NSEvent) {
        tableView.keyDown(with: event)
    }

    // MARK: - Edit ▸ Copy (Cmd+C)

    /// Writes the selection to the pasteboard so every kind of target gets something
    /// useful. Blobs go on as **file promises**, which is what makes ⌘C here and ⌘V
    /// in the Finder download the file — the same mechanism as dragging out, minus
    /// the drag. Each item also carries its `container/key` path and its blob URL,
    /// for editors and browsers respectively. The first item carries the whole joined
    /// path list, so a single-string target gets every selected object.
    @objc func copy(_ sender: Any?) {
        let objects = selectedObjects()
        guard !objects.isEmpty, let location else { return }
        let container = StorageContainer(name: location.container)
        let joinedPaths = objects.map(fullPath(for:)).joined(separator: "\n")

        let writers: [any NSPasteboardWriting] = objects.enumerated().map { index, object in
            let text = index == 0 ? joinedPaths : fullPath(for: object)
            if let provider,
               let promise = BlobFilePromiseProvider.make(
                   for: object, in: container, provider: provider, pathText: text
               ) {
                return promise
            }
            // Folders have nothing to promise; they still copy as a path.
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            return item
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(writers)
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

        // Determine whether there is anything to copy. Copy URL needs a real blob
        // (folders have no shareable object URL).
        let hasTarget = clicked >= 0 || tableView.selectedRow >= 0
        let hasBlobTarget = selectedObjects().contains { !$0.isPrefix }
        menu.items.forEach { item in
            switch item.action {
            case #selector(BrowserSplitViewController.addToSidebar(_:)):
                // Only the coordinator knows what is already saved, so ask whichever
                // responder actually handles the action. This menu manages its own
                // enabled state, so AppKit won't do it for us.
                let handler = NSApp.target(
                    forAction: #selector(BrowserSplitViewController.addToSidebar(_:)), to: nil, from: item
                ) as? any NSUserInterfaceValidations
                item.isEnabled = handler?.validateUserInterfaceItem(item) ?? false
            case #selector(copyName(_:)), #selector(copyPath(_:)):
                item.isEnabled = hasTarget
            case #selector(copyURL(_:)),
                 #selector(BrowserSplitViewController.toggleQuickLook(_:)),
                 #selector(BrowserSplitViewController.downloadSelection(_:)),
                 #selector(BrowserSplitViewController.downloadSelectionTo(_:)):
                item.isEnabled = hasBlobTarget
            default:
                break
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
