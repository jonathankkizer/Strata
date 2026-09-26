import AppKit

// MARK: - ColumnScrollView

/// A single column's scroll area, which scrolls vertically only.
///
/// An `NSScrollView` claims every scroll event it receives, including the horizontal
/// axis it has nothing to do with. Nested inside the strip of columns that does scroll
/// horizontally, that meant a two-finger swipe sideways landed on whichever column the
/// pointer happened to be over and went nowhere, leaving the scroller at the bottom of
/// the window as the only way to move between columns. The Finder swipes.
///
/// So a scroll whose dominant axis is horizontal is handed to the enclosing scroll view
/// instead, with `ScrollAxisLatch` holding that choice steady for the whole gesture.
private final class ColumnScrollView: NSScrollView {

    private var latch = ScrollAxisLatch()

    override func scrollWheel(with event: NSEvent) {
        if latch.route(Self.step(for: event)), let enclosing = enclosingScrollView {
            enclosing.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    private static func step(for event: NSEvent) -> ScrollAxisLatch.Step {
        let phase = event.phase
        if phase.contains(.began) || phase.contains(.mayBegin) {
            return .begins(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            return .ends
        }
        // A phaseless event with no momentum behind it is a discrete wheel notch (or a
        // shift-wheel). Momentum events belong to the gesture that threw them.
        if phase.isEmpty && event.momentumPhase.isEmpty {
            return .standalone(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
        }
        return .continues
    }
}

// MARK: - ColumnDividerView

/// The grab area on a column's trailing edge. Dragging it resizes the column, so a long
/// name can be read without leaving Columns view — the Finder's affordance, in the
/// Finder's place.
@MainActor
private final class ColumnDividerView: NSView {

    var onDragBegan: (() -> Void)?
    /// Live drag: the horizontal distance from where the drag started, and whether the
    /// user is holding Option to resize every column at once.
    var onDrag: ((CGFloat, Bool) -> Void)?
    var onDragEnded: (() -> Void)?
    /// Double-click: size to fit the longest name, all columns when Option is held.
    var onSizeToFit: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,   // ignored, `.inVisibleRect` keeps it in step with scrolling
            options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDown(with event: NSEvent) {
        let resizeAll = event.modifierFlags.contains(.option)

        if event.clickCount == 2 {
            onSizeToFit?(resizeAll)
            return
        }

        guard let window else { return }
        let start = event.locationInWindow
        onDragBegan?()

        // Track in window coordinates: this view moves as the column it belongs to
        // resizes, so its own coordinate space shifts under the pointer mid-drag.
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration, mode: .eventTracking) { tracked, stop in
            // A nil event means tracking was torn down out from under us; end the drag
            // there too, so nothing is left holding state from a gesture that's over.
            guard let tracked, tracked.type != .leftMouseUp else {
                stop.pointee = true
                self.onDragEnded?()
                return
            }
            self.onDrag?(tracked.locationInWindow.x - start.x, resizeAll)
        }
    }
}

// MARK: - BrowseColumn

/// One column in the Miller columns browser: a fixed-width pane listing the
/// folders and blobs at a single prefix.
@MainActor
private final class BrowseColumn: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    let location: BrowserLocation
    let containerView: NSView

    private let tableView = KeyNavTableView()
    private let scrollView = ColumnScrollView()
    private let spinner = NSProgressIndicator()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let divider = ColumnDividerView()
    private var widthConstraint: NSLayoutConstraint!

    /// The rows shown: everything listed (`allItems`), narrowed by `filterText`.
    private(set) var items: [StorageObject] = []
    /// Everything listed for this column's folder.
    private(set) var allItems: [StorageObject] = []
    var loadToken = 0

    /// Only the column showing the current folder is ever filtered; the rest keep "".
    var filterText = "" {
        didSet {
            guard filterText != oldValue else { return }
            refreshVisibleItems()
            reloadTable()
            if items.isEmpty, !allItems.isEmpty {
                showEmptyLabel("No Matches")
            } else if !items.isEmpty {
                emptyLabel.isHidden = true
            }
        }
    }

    func setItems(_ newItems: [StorageObject]) {
        allItems = newItems
        refreshVisibleItems()
    }

    private func refreshVisibleItems() {
        let text = filterText.trimmingCharacters(in: .whitespaces)
        items = text.isEmpty ? allItems : allItems.filter { displayName(for: $0).localizedStandardContains(text) }
    }

    /// Called when the selection changes, with everything selected (empty on deselect).
    var onSelectionChange: (([StorageObject]) -> Void)?
    /// → — enter the selected folder's child column.
    var onEnter: (() -> Void)?
    /// ⌘↓ — open the selection: enter a folder, or download a blob.
    var onOpen: (() -> Void)?
    /// Space — Quick Look the selection.
    var onSpace: (() -> Void)?
    /// ← — move focus to the parent column.
    var onExit: (() -> Void)?
    /// Resolves an object to its shareable URL (provider-supplied), for Copy URL.
    var objectURL: ((StorageObject) -> URL?)?
    /// Builds the drag-out file promise for an object (provider-supplied).
    var makePromise: ((StorageObject) -> BlobFilePromiseProvider?)?
    /// Builds the sidebar drag payload for a folder (provider-supplied).
    var makeLocationDrag: ((StorageObject) -> NSPasteboardItem?)?
    /// The trailing divider was grabbed — the widths as they stand now are what the
    /// drag's deltas are measured against.
    var onResizeBegan: (() -> Void)?
    /// The trailing divider is being dragged: distance from the drag's start, and
    /// whether Option is held to move every column together.
    var onResize: ((CGFloat, Bool) -> Void)?
    /// The divider was released — the width the user settled on is now the default.
    var onResizeEnded: (() -> Void)?
    /// The divider was double-clicked: fit the longest name, or all columns' names.
    var onSizeToFit: ((Bool) -> Void)?

    /// The column's content width, excluding its trailing separator.
    var width: CGFloat = ColumnLayout.defaultWidth {
        didSet {
            guard width != oldValue else { return }
            widthConstraint.constant = width + ColumnLayout.separatorWidth
        }
    }

    /// How wide this column would have to be for its longest name to fit, measured
    /// against the font the rows actually draw in.
    var widthToFitContents: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let longest = items.reduce(CGFloat.zero) { widest, item in
            let name = displayName(for: item) as NSString
            return max(widest, name.size(withAttributes: [.font: font]).width)
        }
        return ColumnLayout.widthToFit(longestNameWidth: longest)
    }

    /// Make this column's table the first responder (used by ←/→ navigation).
    func focus() {
        containerView.window?.makeFirstResponder(tableView)
    }

    var isTableFirstResponder: Bool {
        containerView.window?.firstResponder === tableView
    }

    /// The selected row in screen coordinates, for Quick Look's zoom animation.
    var selectedRowScreenRect: NSRect? {
        let row = tableView.selectedRow
        guard row >= 0, let window = tableView.window else { return nil }
        let rowRect = tableView.rect(ofRow: row)
        guard tableView.visibleRect.intersects(rowRect) else { return nil }
        return window.convertToScreen(tableView.convert(rowRect, to: nil))
    }

    /// Replays a key event into the table, so arrow keys keep working while the
    /// Quick Look panel has keyboard focus.
    func forwardKeyDown(_ event: NSEvent) {
        tableView.keyDown(with: event)
    }

    /// The one selected object, when exactly one is selected.
    var selectedObject: StorageObject? {
        let rows = tableView.selectedRowIndexes
        guard rows.count == 1, let row = rows.first, row < items.count else { return nil }
        return items[row]
    }

    var selectedObjects: [StorageObject] {
        tableView.selectedRowIndexes.compactMap { $0 < items.count ? items[$0] : nil }
    }

    func selectRows(forKeys keys: Set<String>) {
        let indexes = IndexSet(items.indices.filter { keys.contains(items[$0].key) })
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    init(location: BrowserLocation, width: CGFloat) {
        self.location = location
        self.width = ColumnLayout.clamp(width)
        containerView = NSView()
        super.init()
        buildView()
    }

    private func buildView() {
        containerView.translatesAutoresizingMaskIntoConstraints = false

        // Vertical table scroll area. The single column must fill the column's
        // width (else names truncate early with empty space to their right).
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col"))
        tableColumn.resizingMask = .autoresizingMask
        tableColumn.width = 244
        tableColumn.minWidth = 80
        tableView.addTableColumn(tableColumn)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.headerView = nil
        tableView.rowHeight = 24
        // Plain (not .sourceList): the source-list material only paints where rows
        // exist, leaving empty columns a different colour. Plain + an explicit
        // background keeps every column uniform.
        tableView.style = .plain
        tableView.backgroundColor = .controlBackgroundColor
        // Shift- and ⌘-click select several, as in the Finder. Only a single folder
        // opens the next column; several things selected just stay selected.
        tableView.allowsMultipleSelection = true
        tableView.registerForDraggedTypes([.fileURL])
        tableView.dataSource = self
        tableView.delegate = self
        tableView.focusRingType = .none
        tableView.onCommandDown = { [weak self] in self?.onOpen?() }
        tableView.onArrowRight = { [weak self] in self?.onEnter?() }
        tableView.onArrowLeft = { [weak self] in self?.onExit?() }
        tableView.onSpace = { [weak self] in self?.onSpace?() }

        // Blobs drag out to Finder; folders drag to the sidebar. Same as the list.
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        tableView.setAccessibilityLabel("Objects")

        let menu = NSMenu()
        let quickLook = NSMenuItem(title: "Quick Look", action: #selector(BrowserSplitViewController.toggleQuickLook(_:)), keyEquivalent: "")
        quickLook.target = nil   // routed via the responder chain
        let download = NSMenuItem(title: "Download", action: #selector(BrowserSplitViewController.downloadSelection(_:)), keyEquivalent: "")
        download.target = nil   // routed via the responder chain
        let downloadTo = NSMenuItem(title: "Download To\u{2026}", action: #selector(BrowserSplitViewController.downloadSelectionTo(_:)), keyEquivalent: "")
        downloadTo.target = nil
        let copyName = NSMenuItem(title: "Copy Name", action: #selector(copyName(_:)), keyEquivalent: "")
        copyName.target = self
        let copyPath = NSMenuItem(title: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "")
        copyPath.target = self
        let copyURL = NSMenuItem(title: "Copy URL", action: #selector(copyURL(_:)), keyEquivalent: "")
        copyURL.target = self
        let addToSidebar = NSMenuItem(title: "Add to Sidebar", action: #selector(BrowserSplitViewController.addToSidebar(_:)), keyEquivalent: "")
        addToSidebar.target = nil   // routed via the responder chain
        let delete = NSMenuItem(title: "Delete\u{2026}", action: #selector(BrowserSplitViewController.deleteSelection(_:)), keyEquivalent: "")
        delete.target = nil   // routed via the responder chain
        menu.addItem(quickLook)
        menu.addItem(download)
        menu.addItem(downloadTo)
        menu.addItem(.separator())
        menu.addItem(delete)
        menu.addItem(.separator())
        menu.addItem(addToSidebar)
        menu.addItem(.separator())
        menu.addItem(copyName)
        menu.addItem(copyPath)
        menu.addItem(copyURL)
        menu.addItem(.separator())
        menu.addItem(SortMenu.makeItem(shortcuts: false))
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
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

        // The grab area straddles the hairline, sitting on top of it so it hit-tests
        // first. It reaches back into this column rather than over into the next: a
        // subview outside its superview's bounds is not reliably hit-tested.
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.onDragBegan = { [weak self] in self?.onResizeBegan?() }
        divider.onDrag = { [weak self] delta, all in self?.onResize?(delta, all) }
        divider.onDragEnded = { [weak self] in self?.onResizeEnded?() }
        divider.onSizeToFit = { [weak self] all in self?.onSizeToFit?(all) }

        containerView.addSubview(scrollView)
        containerView.addSubview(spinner)
        containerView.addSubview(emptyLabel)
        containerView.addSubview(separator)
        containerView.addSubview(divider)

        widthConstraint = containerView.widthAnchor.constraint(
            equalToConstant: width + ColumnLayout.separatorWidth
        )

        NSLayoutConstraint.activate([
            widthConstraint,

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
            separator.widthAnchor.constraint(equalToConstant: ColumnLayout.separatorWidth),

            divider.topAnchor.constraint(equalTo: containerView.topAnchor),
            divider.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 6),
        ])
    }

    // MARK: - Load state helpers

    func showSpinner() {
        spinner.startAnimation(nil)
        emptyLabel.isHidden = true
    }

    func showEmptyLabel(_ text: String, toolTip: String? = nil) {
        spinner.stopAnimation(nil)
        emptyLabel.stringValue = text
        emptyLabel.toolTip = toolTip
        emptyLabel.isHidden = false
    }

    func hideOverlays() {
        spinner.stopAnimation(nil)
        emptyLabel.isHidden = true
    }

    func deselectAll() {
        tableView.deselectAll(nil)
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
        onSelectionChange?(selectedObjects)
    }

    // MARK: Drops from the Finder

    /// Called with the dropped files and where they should go.
    var onDropFiles: (([URL], BrowserLocation) -> Void)?

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
        // Onto a folder row: that folder. Anywhere else: this column's folder.
        if !(dropOperation == .on && row >= 0 && row < items.count && items[row].isPrefix) {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        let destination = dropOperation == .on && row >= 0 && row < items.count && items[row].isPrefix
            ? BrowserLocation(container: location.container, prefix: items[row].key)
            : location
        onDropFiles?(urls, destination)
        return true
    }

    /// Type-to-select, matching the list surface and every native Mac list.
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard row < items.count else { return nil }
        return displayName(for: items[row])
    }

    /// Blobs drag out as file promises; folders carry a location for the sidebar.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row < items.count else { return nil }
        let item = items[row]
        if item.isPrefix { return makeLocationDrag?(item) }
        return makePromise?(item)
    }

    // MARK: - NSMenuDelegate

    /// Follow Finder: right-clicking an unselected row selects it first, so the
    /// menu — including the responder-chain Download commands — acts on what the
    /// user actually clicked.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let clicked = tableView.clickedRow
        // Right-clicking inside a multiple selection acts on all of it, as in the Finder.
        guard clicked >= 0, !tableView.selectedRowIndexes.contains(clicked) else { return }
        tableView.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
    }

    // MARK: - Copy Name / Copy Path (right-click, Finder parity)

    private func clickedItem() -> StorageObject? {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return nil }
        return items[row]
    }

    @objc private func copyName(_ sender: Any?) {
        guard let item = clickedItem() else { return }
        copyToPasteboard(displayName(for: item))
    }

    @objc private func copyPath(_ sender: Any?) {
        guard let item = clickedItem() else { return }
        var key = item.key
        if key.hasSuffix("/") { key.removeLast() }
        copyToPasteboard("\(location.container)/\(key)")
    }

    @objc private func copyURL(_ sender: Any?) {
        guard let item = clickedItem(), !item.isPrefix, let url = objectURL?(item) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, .URL], owner: nil)
        pasteboard.setString(url.absoluteString, forType: .string)
        pasteboard.setString(url.absoluteString, forType: .URL)
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
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
        label.allowsExpansionToolTips = true
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

            // Keep the chevron clear of the vertical overlay scroller at the edge.
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 11),
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

    /// Everything selected in the column being worked in.
    var onSelectionChange: (([StorageObject]) -> Void)?

    /// Files dropped onto a column, with the folder they were dropped into.
    var onDropFiles: (([URL], BrowserLocation) -> Void)?

    /// Fired when the deepest browse location changes, so the shared path bar updates.
    var onLocationChange: ((BrowserLocation?) -> Void)?

    private(set) var location: BrowserLocation? {
        didSet {
            guard location != oldValue else { return }
            onLocationChange?(location)
        }
    }

    // MARK: - Private layout

    private let outerScrollView = NSScrollView()
    private let stackView = NSStackView()

    // Live columns in left-to-right order.
    private var columns: [BrowseColumn] = []

    /// Current sort, shared with the list via the facade.
    private var sort = BrowseSort()

    // While auto-expanding to a deep prefix, `expand(column:segments:)` drives
    // column creation itself, so the selection callback must not also open columns.
    private var isAutoExpanding = false

    /// True while a reload or re-sort puts the same object back under the selection.
    /// Its row index usually moves, which the table reports as a selection change;
    /// treated as a real one, that closed every column to the right, re-fetched the
    /// next one and pushed a Back entry — collapsing the path on ⌘R or a sort change.
    private var isReselecting = false

    /// True only while a location change comes from moving focus between columns that
    /// are already open, rather than from navigating somewhere new. The coordinator
    /// reads it to keep Back/Forward a record of navigation instead of of keystrokes.
    private(set) var isFocusMove = false

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
        // Narrow columns can leave the strip shorter than the pane. That gap is the
        // outer scroll view's own background, so it paints what the columns paint.
        outerScrollView.drawsBackground = true
        outerScrollView.backgroundColor = .controlBackgroundColor
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

    // MARK: - For tests (the columns themselves are private)

    /// The folder each open column shows, left to right.
    var openColumnLocations: [BrowserLocation] { columns.map(\.location) }

    func rowCount(inColumnAt index: Int) -> Int {
        index < columns.count ? columns[index].items.count : 0
    }

    /// Selects rows in column `index` as a click would, including what follows from it.
    func select(keys: Set<String>, inColumnAt index: Int) {
        columns[index].selectRows(forKeys: keys)
    }

    func show(_ newLocation: BrowserLocation) {
        clearColumns()
        messageLabel.isHidden = true
        outerScrollView.isHidden = false

        guard provider != nil else { return }

        // Publish the destination up front. `clearColumns` just nilled the location,
        // and for a container root nothing else would ever set it — leaving the path
        // bar and window title empty until the user clicked something.
        location = newLocation

        let rootLocation = BrowserLocation(container: newLocation.container, prefix: "")
        let col = addColumn(at: rootLocation)

        // After the root column loads, auto-expand into the requested prefix.
        let segments = newLocation.prefix.split(separator: "/").map(String.init)
        loadColumn(col, thenExpand: segments)

        // Take keyboard focus so the arrow keys drive the columns immediately
        // (rather than the sidebar the user just clicked).
        col.focus()
    }

    // MARK: - Enclosing-folder navigation (⌘↑ / ←)

    var canNavigateUp: Bool {
        if let idx = focusedColumnIndex { return idx > 0 }
        return columns.count > 1
    }

    func navigateUp() {
        let idx = focusedColumnIndex ?? (columns.isEmpty ? nil : columns.count - 1)
        guard let idx, idx > 0 else { return }
        focusColumn(at: idx - 1)
    }

    private var focusedColumnIndex: Int? {
        columns.firstIndex { $0.isTableFirstResponder }
    }

    // MARK: - Focus

    /// Moves keyboard focus to a column and brings the rest of the UI with it: the
    /// column is scrolled into view, and the browse location (path bar, window title,
    /// what the Download/Quick Look commands act on) follows the selection there.
    ///
    /// Focus used to move on its own, which left the focused column scrolled off to
    /// the left while the path bar still described a folder several columns deeper.
    private func focusColumn(at index: Int) {
        guard columns.indices.contains(index) else { return }
        columns[index].focus()
        scrollToReveal(columnAt: index)
        syncLocationToFocus()
    }

    /// Republishes the location for the focused column, using the same rule a click
    /// uses: a selected folder *is* the location, anything else means the column's
    /// own folder.
    private func syncLocationToFocus() {
        guard let index = focusedColumnIndex else { return }
        let col = columns[index]
        // Flagged so the coordinator can tell a focus move from a real navigation and
        // keep Back/Forward meaningful — arrowing between open columns should not
        // pile up history entries.
        isFocusMove = true
        defer { isFocusMove = false }

        if let selected = col.selectedObject, selected.isPrefix {
            location = BrowserLocation(container: col.location.container, prefix: selected.key)
        } else {
            location = col.location
        }
    }

    func reload() {
        // Re-run the load for every open column, preserving selected keys where possible.
        let snapshot = columns
        for col in snapshot {
            loadColumnPreservingKey(col, selectedKeys: Set(col.selectedObjects.map(\.key)))
        }
    }

    func showMessage(_ text: String) {
        clearColumns()
        messageLabel.stringValue = text
        messageLabel.isHidden = false
        outerScrollView.isHidden = true
    }

    /// Open the selection — ⌘O / ⌘↓ / →. A folder enters its column; a blob downloads,
    /// matching the list surface. Acts on the focused column, so it opens what is
    /// highlighted rather than whatever sits deepest.
    func openSelection() {
        guard let col = activeColumn, let object = col.selectedObject else { return }
        if object.isPrefix {
            enterChild(of: col)
        } else {
            NSApp.sendAction(#selector(BrowserSplitViewController.downloadSelection(_:)), to: nil, from: self)
        }
    }

    // MARK: - Column management

    @discardableResult
    private func addColumn(at location: BrowserLocation) -> BrowseColumn {
        // A new column opens at whatever width the user last settled on, so navigating
        // deeper doesn't snap back to a default they've already rejected.
        let col = BrowseColumn(location: location, width: StrataDefaults.columnWidth)
        columns.append(col)
        stackView.addArrangedSubview(col.containerView)

        // Pin the column view to the stack's full height.
        col.containerView.heightAnchor.constraint(equalTo: stackView.heightAnchor).isActive = true

        col.onSelectionChange = { [weak self, weak col] objects in
            guard let self, let col else { return }
            self.handleSelection(objects, inColumn: col)
        }
        col.onDropFiles = { [weak self] urls, destination in
            self?.onDropFiles?(urls, destination)
        }
        col.onEnter = { [weak self, weak col] in
            guard let self, let col else { return }
            self.enterChild(of: col)
        }
        col.onOpen = { [weak self] in self?.openSelection() }
        col.onSpace = { [weak self] in
            NSApp.sendAction(#selector(BrowserSplitViewController.toggleQuickLook(_:)), to: nil, from: self)
        }
        col.onExit = { [weak self, weak col] in
            guard let self, let col else { return }
            self.focusParent(of: col)
        }
        col.objectURL = { [weak self] object in
            guard let self, let provider = self.provider else { return nil }
            return provider.objectURL(forKey: object.key, in: StorageContainer(name: location.container))
        }
        col.makeLocationDrag = { [weak self] object in
            guard let self, let provider = self.provider else { return nil }
            return LocationDrag(
                account: provider.account,
                location: BrowserLocation(container: location.container, prefix: object.key)
            ).pasteboardItem()
        }
        col.makePromise = { [weak self] object in
            guard let self, let provider = self.provider else { return nil }
            return BlobFilePromiseProvider.make(
                for: object,
                in: StorageContainer(name: location.container),
                provider: provider
            )
        }
        col.onResizeBegan = { [weak self] in self?.beginResize() }
        col.onResize = { [weak self, weak col] delta, all in
            guard let self, let col else { return }
            self.resize(col, by: delta, resizingAll: all)
        }
        col.onResizeEnded = { [weak self, weak col] in
            guard let self, let col else { return }
            self.finishResize(settledAt: col.width)
        }
        col.onSizeToFit = { [weak self, weak col] all in
            guard let self, let col else { return }
            self.sizeToFit(col, resizingAll: all)
        }
        return col
    }

    // MARK: - Column widths

    /// Widths as they stood when the current drag began. Deltas are applied to these
    /// rather than accumulated, so a drag that hits the minimum and comes back lands
    /// where the pointer is instead of trailing behind it.
    private var resizeBaseline: [CGFloat] = []

    private func beginResize() {
        resizeBaseline = columns.map(\.width)
    }

    /// Live resize from a divider drag. Without Option only the dragged column moves;
    /// with it every column matches, which is how the Finder offers "all of them".
    private func resize(_ col: BrowseColumn, by delta: CGFloat, resizingAll: Bool) {
        guard let index = columns.firstIndex(where: { $0 === col }),
              resizeBaseline.indices.contains(index) else { return }
        let target = ColumnLayout.clamp(resizeBaseline[index] + delta)
        for column in (resizingAll ? columns : [col]) { column.width = target }
        layoutColumns()
    }

    private func finishResize(settledAt width: CGFloat) {
        resizeBaseline = []
        StrataDefaults.columnWidth = width
    }

    /// Double-click: widen (or narrow) to exactly what the names need. With Option every
    /// column fits its *own* longest name — the Finder's "right size all columns" —
    /// rather than all of them adopting the clicked column's width.
    private func sizeToFit(_ col: BrowseColumn, resizingAll: Bool) {
        for column in (resizingAll ? columns : [col]) {
            column.width = column.widthToFitContents
        }
        layoutColumns()
        StrataDefaults.columnWidth = col.width
    }

    /// Flush the constraint change immediately: a resize that only lands on the next
    /// pass through the run loop reads as lag against the pointer.
    private func layoutColumns() {
        stackView.layoutSubtreeIfNeeded()
    }

    // MARK: - Selection (for Download)

    /// The column the user is acting on. The focused one wins: after arrowing back to
    /// a parent, Download, Quick Look, and Copy must act on the row highlighted there,
    /// not on a deeper column the user has navigated away from. Falls back to the
    /// deepest selection when focus is elsewhere entirely (a toolbar click, say).
    private var activeColumn: BrowseColumn? {
        if let index = focusedColumnIndex { return columns[index] }
        return columns.last(where: { !$0.selectedObjects.isEmpty })
    }

    /// Everything selected in the active column, folders included.
    var selection: [StorageObject] {
        activeColumn?.selectedObjects ?? []
    }

    /// The real blobs in the current selection.
    var downloadableSelection: [StorageObject] {
        selection.filter { !$0.isPrefix }
    }

    /// The container the selection lives in.
    var selectedContainerName: String? {
        activeColumn?.location.container ?? location?.container
    }

    /// A selected folder — what "Add to Sidebar" saves.
    var selectedFolder: StorageObject? {
        guard let object = activeColumn?.selectedObject, object.isPrefix else { return nil }
        return object
    }

    /// The selected row in screen coordinates, for Quick Look's zoom animation.
    var selectedRowScreenRect: NSRect? {
        activeColumn?.selectedRowScreenRect
    }

    /// Replays a key event into the focused column's table.
    func forwardKeyDown(_ event: NSEvent) {
        activeColumn?.forwardKeyDown(event)
    }

    /// Cmd+C: copy the selection — each real blob as a file promise (so
    /// pasting into the Finder downloads it), plus its path and URL. Matches the
    /// list surface.
    @objc func copy(_ sender: Any?) {
        guard let col = activeColumn else { return }
        let objects = col.selectedObjects
        guard !objects.isEmpty else { return }
        let container = StorageContainer(name: col.location.container)
        let path: (StorageObject) -> String = { object in
            var key = object.key
            if key.hasSuffix("/") { key.removeLast() }
            return "\(container.name)/\(key)"
        }
        // The first item carries every path, so pasting as text gives the lot.
        let joinedPaths = objects.map(path).joined(separator: "\n")

        let writers: [any NSPasteboardWriting] = objects.enumerated().map { index, object in
            let text = index == 0 ? joinedPaths : path(object)
            if let provider,
               let promise = BlobFilePromiseProvider.make(
                   for: object, in: container, provider: provider, pathText: text
               ) {
                return promise
            }
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            return item
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(writers)
    }

    /// Move into the selected folder's (already-open) child column and focus it.
    private func enterChild(of col: BrowseColumn) {
        guard let idx = columns.firstIndex(where: { $0 === col }),
              col.selectedObject?.isPrefix == true else { return }
        let childIndex = idx + 1
        guard childIndex < columns.count else { return }
        columns[childIndex].selectFirstRow()
        focusColumn(at: childIndex)
    }

    /// Move focus to the parent column (←).
    private func focusParent(of col: BrowseColumn) {
        guard let idx = columns.firstIndex(where: { $0 === col }), idx > 0 else { return }
        focusColumn(at: idx - 1)
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

    private func handleSelection(_ objects: [StorageObject], inColumn col: BrowseColumn) {
        let object = objects.count == 1 ? objects.first : nil
        // Programmatic selection during auto-expand is driven by expand(); ignore it
        // here so we don't open a duplicate column.
        guard !isAutoExpanding, !isReselecting else { return }
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
            // Nothing, or several things, selected: nothing opens, and the location
            // is this column's own folder.
            location = col.location
        }

        onSelectionChange?(objects)
    }

    private func scrollToRevealLastColumn() {
        scrollToReveal(columnAt: columns.count - 1)
    }

    /// Scrolls the horizontal strip so a column is fully on screen. `scrollToVisible`
    /// moves the minimum needed, so revealing a column to the left parks it against
    /// the leading edge with its children still visible to the right — the same
    /// framing the Finder settles on.
    private func scrollToReveal(columnAt index: Int) {
        guard columns.indices.contains(index) else { return }
        // Flush the layout so the frame is valid before we scroll.
        stackView.layoutSubtreeIfNeeded()
        let frame = outerScrollView.contentView.convert(columns[index].containerView.frame, from: stackView)
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
                col.setItems(objects.sorted(by: self.sort.areInOrder))
                col.reloadTable()
                col.hideOverlays()
                if objects.isEmpty { col.showEmptyLabel("Empty") }

                // Continue the auto-expand chain if segments remain.
                if !segments.isEmpty {
                    self.expand(column: col, segments: segments)
                }

            case .failure(let error):
                col.setItems([])
                col.reloadTable()
                self.showError(error, in: col)
            }
        }
    }

    /// `reload()` variant that preserves the previously selected row.
    private func loadColumnPreservingKey(_ col: BrowseColumn, selectedKeys: Set<String>) {
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
                self.isReselecting = true
                col.setItems(objects.sorted(by: self.sort.areInOrder))
                col.reloadTable()
                col.hideOverlays()
                if objects.isEmpty { col.showEmptyLabel("Empty") }
                let remaining = selectedKeys.filter { key in col.items.contains { $0.key == key } }
                if remaining.isEmpty {
                    col.deselectAll()
                } else {
                    col.selectRows(forKeys: remaining)
                }
                self.isReselecting = false
                // What was selected is gone: close what it had open, as if the user
                // had clicked empty space, rather than leave a different row
                // highlighted beside the old folder's contents.
                if !selectedKeys.isEmpty, remaining.isEmpty {
                    self.handleSelection([], inColumn: col)
                }

            case .failure(let error):
                col.setItems([])
                col.reloadTable()
                self.showError(error, in: col)
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
        guard let item = col.items.first(where: { $0.key == targetKey }), item.isPrefix else {
            // The saved path no longer exists. Settle where we actually got to, and
            // put focus there, rather than claiming to be somewhere we are not.
            if let index = columns.firstIndex(where: { $0 === col }) {
                focusColumn(at: index)
            }
            return
        }

        isAutoExpanding = true
        col.selectRow(for: targetKey)
        isAutoExpanding = false
        // Intermediate steps are deliberately not published: `show` already set the
        // destination, and announcing every rung of the ladder would flicker the path
        // bar and stack up spurious Back entries on the way to one folder.

        // Open next column and continue.
        let nextLocation = BrowserLocation(container: col.location.container, prefix: item.key)
        let nextCol = addColumn(at: nextLocation)
        loadColumn(nextCol, thenExpand: rest)

        if rest.isEmpty, let index = columns.firstIndex(where: { $0 === col }) {
            // Arrived. Focus the column holding the selection and scroll it into
            // view — otherwise a deep navigation left focus stranded on column 0
            // while the strip was scrolled to the far right, so the first arrow key
            // moved a highlight the user could not see.
            focusColumn(at: index)
        } else {
            scrollToRevealLastColumn()
        }
    }

    // MARK: - Find

    /// Filters the column showing the current folder, keeping its selection. Every
    /// other column is left unfiltered.
    func applyFilter(_ text: String) {
        isReselecting = true
        defer { isReselecting = false }
        let target = columns.last { $0.location == location }
        for col in columns {
            let wanted = col === target ? text : ""
            guard col.filterText != wanted else { continue }
            let selectedKeys = Set(col.selectedObjects.map(\.key))
            col.filterText = wanted
            if !selectedKeys.isEmpty { col.selectRows(forKeys: selectedKeys) }
        }
    }

    // MARK: - Sorting (folders always before blobs)

    /// Re-sorts every open column and reloads, preserving each column's selection.
    func applySort(_ newSort: BrowseSort) {
        sort = newSort
        isReselecting = true
        defer { isReselecting = false }
        for col in columns {
            let selectedKeys = Set(col.selectedObjects.map(\.key))
            col.setItems(col.allItems.sorted(by: sort.areInOrder))
            col.reloadTable()
            if !selectedKeys.isEmpty { col.selectRows(forKeys: selectedKeys) }
        }
    }

    // MARK: - Error messages (compact one-line)

    /// A column is narrow, so it shows the one-line summary; the advice that goes
    /// with it is in the tooltip rather than lost.
    private func showError(_ error: Error, in column: BrowseColumn) {
        let message = StorageErrorText.message(for: error, kind: provider?.kind ?? .azureBlob)
        column.showEmptyLabel(message.summary, toolTip: message.full)
    }
}
