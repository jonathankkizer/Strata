import AppKit

// MARK: - BrowseColumn

/// One column in the Miller columns browser: a fixed-width pane listing the
/// folders and blobs at a single prefix.
@MainActor
private final class BrowseColumn: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    let location: BrowserLocation
    let containerView: NSView

    private let tableView = KeyNavTableView()
    private let scrollView = NSScrollView()
    private let spinner = NSProgressIndicator()
    private let emptyLabel = NSTextField(labelWithString: "")

    var items: [StorageObject] = []
    var loadToken = 0

    /// Called when the selection changes (folder or blob, or nil on deselect).
    var onSelectionChange: ((StorageObject?) -> Void)?
    /// ⌘↓ / → — enter the selected folder's child column.
    var onEnter: (() -> Void)?
    /// ← — move focus to the parent column.
    var onExit: (() -> Void)?

    /// Make this column's table the first responder (used by ←/→ navigation).
    func focus() {
        containerView.window?.makeFirstResponder(tableView)
    }

    var selectedObject: StorageObject? {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return nil }
        return items[row]
    }

    init(location: BrowserLocation) {
        self.location = location
        containerView = NSView()
        super.init()
        buildView()
    }

    private func buildView() {
        containerView.translatesAutoresizingMaskIntoConstraints = false

        // Vertical table scroll area.
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col"))
        tableColumn.resizingMask = []
        tableView.addTableColumn(tableColumn)
        tableView.headerView = nil
        tableView.rowHeight = 24
        // .sourceList gives the sidebar look; fall back to plain if needed.
        tableView.style = .sourceList
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.focusRingType = .none
        tableView.onCommandDown = { [weak self] in self?.onEnter?() }
        tableView.onArrowRight = { [weak self] in self?.onEnter?() }
        tableView.onArrowLeft = { [weak self] in self?.onExit?() }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Spinner centered over the scroll area.
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        // Single-line "Empty" / error label centered in the column.
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        // 1pt trailing separator (NSBox .separator draws a hairline).
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(scrollView)
        containerView.addSubview(spinner)
        containerView.addSubview(emptyLabel)
        containerView.addSubview(separator)

        NSLayoutConstraint.activate([
            // Fixed column width.
            containerView.widthAnchor.constraint(equalToConstant: 261),  // 260 content + 1 separator

            scrollView.topAnchor.constraint(equalTo: containerView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: separator.leadingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 230),

            // 1pt trailing separator pinned to the right edge.
            separator.topAnchor.constraint(equalTo: containerView.topAnchor),
            separator.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    // MARK: - Load state helpers

    func showSpinner() {
        spinner.startAnimation(nil)
        emptyLabel.isHidden = true
    }

    func showEmptyLabel(_ text: String) {
        spinner.stopAnimation(nil)
        emptyLabel.stringValue = text
        emptyLabel.isHidden = false
    }

    func hideOverlays() {
        spinner.stopAnimation(nil)
        emptyLabel.isHidden = true
    }

    func selectRow(for key: String) {
        guard let idx = items.firstIndex(where: { $0.key == key }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        tableView.scrollRowToVisible(idx)
    }

    func selectFirstRow() {
        guard !items.isEmpty else { return }
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
    }

    func reloadTable() {
        tableView.reloadData()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]
        return makeNameCell(for: item, in: tableView)
    }

    private func makeNameCell(for item: StorageObject, in tableView: NSTableView) -> NSView {
        let id = NSUserInterfaceItemIdentifier("browseColName")

        // Reuse or create: same pattern as ObjectListViewController.nameCell().
        let cell: ColumnNameCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? ColumnNameCellView {
            cell = reused
        } else {
            cell = ColumnNameCellView()
            cell.identifier = id
        }

        cell.configure(name: displayName(for: item), icon: BlobIcon.image(for: item), showChevron: item.isPrefix)
        return cell
    }

    private func displayName(for item: StorageObject) -> String {
        var key = item.key
        if !location.prefix.isEmpty, key.hasPrefix(location.prefix) {
            key.removeFirst(location.prefix.count)
        }
        if item.isPrefix, key.hasSuffix("/") { key.removeLast() }
        return key
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?(selectedObject)
    }
}

// MARK: - ColumnNameCellView

/// A reusable table cell: [icon] [name label] [optional chevron].
@MainActor
private final class ColumnNameCellView: NSTableCellView {

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.imageScaling = .scaleProportionallyUpOrDown

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .tertiaryLabelColor

        addSubview(icon)
        addSubview(label)
        addSubview(chevron)
        imageView = icon
        textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -4),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
        ])
    }

    func configure(name: String, icon iconImage: NSImage?, showChevron: Bool) {
        label.stringValue = name
        icon.image = iconImage
        chevron.isHidden = !showChevron
    }
}

// MARK: - ColumnBrowserViewController

@MainActor
final class ColumnBrowserViewController: NSViewController {

    var provider: (any StorageProvider)?

    var onSelectionChange: ((StorageObject?) -> Void)?

    private(set) var location: BrowserLocation?

    // MARK: - Private layout

    private let outerScrollView = NSScrollView()
    private let stackView = NSStackView()

    // Live columns in left-to-right order.
    private var columns: [BrowseColumn] = []

    // While auto-expanding to a deep prefix, `expand(column:segments:)` drives
    // column creation itself, so the selection callback must not also open columns.
    private var isAutoExpanding = false

    // Message label shown when there is nothing to browse yet.
    private let messageLabel = NSTextField(labelWithString: "")

    // MARK: - View lifecycle

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
    }

    private func buildLayout() {
        // Horizontal-only scroll view.
        outerScrollView.hasHorizontalScroller = true
        outerScrollView.hasVerticalScroller = false
        outerScrollView.autohidesScrollers = true
        outerScrollView.translatesAutoresizingMaskIntoConstraints = false

        // Horizontal stack that grows rightward; each column manages its own width.
        stackView.orientation = .horizontal
        stackView.spacing = 0
        stackView.alignment = .top
        stackView.translatesAutoresizingMaskIntoConstraints = false

        outerScrollView.documentView = stackView

        // stackView height tracks the scroll view's content height.
        let contentView = outerScrollView.contentView
        stackView.topAnchor.constraint(equalTo: contentView.topAnchor).isActive = true
        stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor).isActive = true
        stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor).isActive = true
        // No trailing constraint — the stack can grow past the visible width.

        // Centered message label (shown in place of the scroll view when idle).
        messageLabel.font = .systemFont(ofSize: 14)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.isHidden = true

        view.addSubview(outerScrollView)
        view.addSubview(messageLabel)

        NSLayoutConstraint.activate([
            outerScrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            outerScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            outerScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            outerScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
    }

    // MARK: - Public interface

    func show(_ newLocation: BrowserLocation) {
        clearColumns()
        messageLabel.isHidden = true
        outerScrollView.isHidden = false

        guard provider != nil else { return }

        let rootLocation = BrowserLocation(container: newLocation.container, prefix: "")
        let col = addColumn(at: rootLocation)

        // After the root column loads, auto-expand into the requested prefix.
        let segments = newLocation.prefix.split(separator: "/").map(String.init)
        loadColumn(col, thenExpand: segments)
    }

    func reload() {
        // Re-run the load for every open column, preserving selected keys where possible.
        let snapshot = columns
        for col in snapshot {
            let selectedKey = col.selectedObject?.key
            loadColumnPreservingKey(col, selectedKey: selectedKey)
        }
    }

    func showMessage(_ text: String) {
        clearColumns()
        messageLabel.stringValue = text
        messageLabel.isHidden = false
        outerScrollView.isHidden = true
    }

    /// Open (enter) the deepest selected folder — the ⌘O menu path.
    func openSelection() {
        guard let idx = columns.lastIndex(where: { $0.selectedObject != nil }) else { return }
        enterChild(of: columns[idx])
    }

    // MARK: - Column management

    @discardableResult
    private func addColumn(at location: BrowserLocation) -> BrowseColumn {
        let col = BrowseColumn(location: location)
        columns.append(col)
        stackView.addArrangedSubview(col.containerView)

        // Pin the column view to the stack's full height.
        col.containerView.heightAnchor.constraint(equalTo: stackView.heightAnchor).isActive = true

        col.onSelectionChange = { [weak self, weak col] object in
            guard let self, let col else { return }
            self.handleSelection(object, inColumn: col)
        }
        col.onEnter = { [weak self, weak col] in
            guard let self, let col else { return }
            self.enterChild(of: col)
        }
        col.onExit = { [weak self, weak col] in
            guard let self, let col else { return }
            self.focusParent(of: col)
        }
        return col
    }

    /// Move into the selected folder's (already-open) child column and focus it.
    private func enterChild(of col: BrowseColumn) {
        guard let idx = columns.firstIndex(where: { $0 === col }),
              col.selectedObject?.isPrefix == true else { return }
        let childIndex = idx + 1
        guard childIndex < columns.count else { return }
        columns[childIndex].selectFirstRow()
        columns[childIndex].focus()
    }

    /// Move focus to the parent column (←).
    private func focusParent(of col: BrowseColumn) {
        guard let idx = columns.firstIndex(where: { $0 === col }), idx > 0 else { return }
        columns[idx - 1].focus()
    }

    private func clearColumns() {
        for col in columns {
            stackView.removeArrangedSubview(col.containerView)
            col.containerView.removeFromSuperview()
        }
        columns.removeAll()
        location = nil
    }

    private func removeColumns(after index: Int) {
        guard index + 1 < columns.count else { return }
        let toRemove = columns[(index + 1)...]
        for col in toRemove {
            stackView.removeArrangedSubview(col.containerView)
            col.containerView.removeFromSuperview()
        }
        columns.removeSubrange((index + 1)...)
    }

    // MARK: - Selection handling

    private func handleSelection(_ object: StorageObject?, inColumn col: BrowseColumn) {
        // Programmatic selection during auto-expand is driven by expand(); ignore it
        // here so we don't open a duplicate column.
        guard !isAutoExpanding else { return }
        guard let colIndex = columns.firstIndex(where: { $0 === col }) else { return }

        // Always cull everything to the right of the selected column.
        removeColumns(after: colIndex)

        if let object {
            if object.isPrefix {
                // Folder: open the next column and update location to this folder's prefix.
                location = BrowserLocation(container: col.location.container, prefix: object.key)
                let nextLocation = BrowserLocation(container: col.location.container, prefix: object.key)
                let nextCol = addColumn(at: nextLocation)
                loadColumn(nextCol, thenExpand: [])
                scrollToRevealLastColumn()
            } else {
                // Blob: location stays at the column's own prefix.
                location = col.location
            }
        } else {
            // Empty selection: location reflects this column's prefix.
            location = col.location
        }

        onSelectionChange?(object)
    }

    private func scrollToRevealLastColumn() {
        guard let last = columns.last else { return }
        // Flush the layout so the frame is valid before we scroll.
        stackView.layoutSubtreeIfNeeded()
        let frame = outerScrollView.contentView.convert(last.containerView.frame, from: stackView)
        outerScrollView.contentView.scrollToVisible(frame)
    }

    // MARK: - Async loading

    /// Load `col`, then sequentially auto-expand the remaining `segments`.
    private func loadColumn(_ col: BrowseColumn, thenExpand segments: [String]) {
        guard let provider else { return }

        col.loadToken += 1
        let token = col.loadToken
        col.showSpinner()

        let container = StorageContainer(name: col.location.container)
        let prefix = col.location.prefix

        Task { @MainActor [weak self, weak col] in
            guard let self else { return }

            let result: Result<[StorageObject], Error>
            do {
                result = .success(try await provider.listObjects(in: container, prefix: prefix))
            } catch {
                result = .failure(error)
            }

            guard let col, token == col.loadToken else { return }

            switch result {
            case .success(let objects):
                col.items = Self.sorted(objects)
                col.reloadTable()
                col.hideOverlays()
                if objects.isEmpty { col.showEmptyLabel("Empty") }

                // Continue the auto-expand chain if segments remain.
                if !segments.isEmpty {
                    self.expand(column: col, segments: segments)
                }

            case .failure(let error):
                col.items = []
                col.reloadTable()
                col.showEmptyLabel(Self.shortErrorMessage(error))
            }
        }
    }

    /// `reload()` variant that preserves the previously selected row.
    private func loadColumnPreservingKey(_ col: BrowseColumn, selectedKey: String?) {
        guard let provider else { return }

        col.loadToken += 1
        let token = col.loadToken
        col.showSpinner()

        let container = StorageContainer(name: col.location.container)
        let prefix = col.location.prefix

        Task { @MainActor [weak col] in
            let result: Result<[StorageObject], Error>
            do {
                result = .success(try await provider.listObjects(in: container, prefix: prefix))
            } catch {
                result = .failure(error)
            }

            guard let col, token == col.loadToken else { return }

            switch result {
            case .success(let objects):
                col.items = Self.sorted(objects)
                col.reloadTable()
                col.hideOverlays()
                if objects.isEmpty { col.showEmptyLabel("Empty") }
                if let key = selectedKey { col.selectRow(for: key) }

            case .failure(let error):
                col.items = []
                col.reloadTable()
                col.showEmptyLabel(Self.shortErrorMessage(error))
            }
        }
    }

    /// Best-effort sequential expansion: find the first segment in `col.items`,
    /// select it, open the next column, and recurse for remaining segments.
    private func expand(column col: BrowseColumn, segments: [String]) {
        guard let first = segments.first else { return }
        let rest = Array(segments.dropFirst())

        // The folder key is prefix + segment + "/".
        let targetKey = col.location.prefix + first + "/"
        guard let item = col.items.first(where: { $0.key == targetKey }), item.isPrefix else { return }

        isAutoExpanding = true
        col.selectRow(for: targetKey)
        isAutoExpanding = false
        location = BrowserLocation(container: col.location.container, prefix: item.key)

        // Open next column and continue.
        let nextLocation = BrowserLocation(container: col.location.container, prefix: item.key)
        let nextCol = addColumn(at: nextLocation)
        scrollToRevealLastColumn()
        loadColumn(nextCol, thenExpand: rest)
    }

    // MARK: - Sorting (folders before blobs; localizedStandard within each group)

    private static func sorted(_ objects: [StorageObject]) -> [StorageObject] {
        objects.sorted { lhs, rhs in
            if lhs.isPrefix != rhs.isPrefix { return lhs.isPrefix }
            return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
        }
    }

    // MARK: - Error messages (compact one-line)

    private static func shortErrorMessage(_ error: Error) -> String {
        if case StorageProviderError.dataPlaneForbidden = error {
            return "No data-plane access"
        } else if case StorageProviderError.unauthorized = error {
            return "Not authorized"
        } else {
            return error.localizedDescription
        }
    }
}
