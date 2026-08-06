import AppKit

/// Reference-type outline nodes so NSOutlineView has stable item identity.
private final class SidebarGroup: NSObject {
    enum Kind { case favorites, containers }
    let kind: Kind
    /// Mutable because the containers group is titled in the connected provider's
    /// vocabulary — "Containers" on Azure, "Buckets" on S3.
    var title: String
    var children: [NSObject]

    init(kind: Kind, title: String, children: [NSObject]) {
        self.kind = kind
        self.title = title
        self.children = children
    }
}

private final class SidebarContainerNode: NSObject {
    let container: StorageContainer
    init(_ container: StorageContainer) { self.container = container }
}

private final class SidebarFavoriteNode: NSObject {
    let favorite: Favorite
    init(_ favorite: Favorite) { self.favorite = favorite }
}

/// An outline view that surfaces the one key the source list needs: Return to rename
/// the selected favorite, as in the Finder's sidebar.
final class SidebarOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, let onReturn {   // Return, Enter
            onReturn()
            return
        }
        super.keyDown(with: event)
    }
}

/// Source-list sidebar: the user's saved places on top, then the connected account's
/// containers — the same shape as the Finder's Favorites over Locations.
@MainActor
final class ContainerSidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    var onSelectContainer: ((StorageContainer) -> Void)?
    /// A saved place was chosen. The coordinator decides whether that means
    /// reconnecting to another account first.
    var onSelectFavorite: ((Favorite) -> Void)?
    /// Files were dropped onto a saved place: upload them there.
    var onDropFiles: (([URL], Favorite) -> Void)?
    /// The account currently connected, so dragged-in folders can be attributed and
    /// drops onto other accounts' favorites refused.
    var currentAccount: ProviderAccount?

    private let outlineView = SidebarOutlineView()
    private let scrollView = NSScrollView()

    private let favoritesGroup = SidebarGroup(kind: .favorites, title: "Favorites", children: [])
    private let containersGroup = SidebarGroup(kind: .containers, title: "Containers", children: [])
    /// Only the groups currently shown. The Favorites group is omitted when empty
    /// rather than left as a dead header.
    private var groups: [SidebarGroup] = []

    private var suppressSelectionCallback = false

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("container"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 14
        outlineView.autoresizesOutlineColumn = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.focusRingType = .none
        outlineView.setAccessibilityLabel("Places")
        outlineView.onReturn = { [weak self] in self?.beginRenamingSelectedFavorite() }
        outlineView.menu = makeContextMenu()

        // Accept places dragged in from the browse surfaces (and from the container
        // list), plus files dropped onto a saved place to upload there.
        outlineView.registerForDraggedTypes([.strataLocation, .fileURL])
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: true)

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        // A scroller only when there is something to scroll to. Without this the bar
        // sits there permanently for anyone running "Always show scroll bars" — a
        // handful of favourites in a full-height sidebar has nothing to scroll, and a
        // scroller that can't move is just a stripe down the edge of the app.
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // The sidebar material, installed explicitly.
        //
        // `.sourceList` styling on the outline view doesn't paint a background — it
        // expects to sit on a sidebar material and draws its rows and selection to suit.
        // With the scroll view as this controller's root view and `drawsBackground` off,
        // nothing supplied that material: measured on a running window, every
        // `NSVisualEffectView` in the hierarchy began to the *right* of the sidebar, so
        // the sidebar was bare window background and the titlebar above it had nothing
        // distinct to blend with. That flatness is what made the toolbar read as one
        // undifferentiated strip.
        //
        // `.behindWindow` blending is what makes a sidebar translucent over the desktop,
        // and following the window's active state is what dims it when the window is
        // not frontmost — both are what people read as "this is a sidebar".
        let backdrop = NSVisualEffectView()
        backdrop.material = .sidebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .followsWindowActiveState
        backdrop.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: backdrop.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
        ])

        view = backdrop

        NotificationCenter.default.addObserver(
            self, selector: #selector(favoritesChanged), name: .favoritesDidChange, object: nil
        )
        rebuildGroups()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Content

    func setContainers(_ containers: [StorageContainer]) {
        containersGroup.children = containers.map(SidebarContainerNode.init)
        // Calling an S3 user's buckets "containers" is the kind of small wrongness that
        // makes an app feel like it was built for somebody else.
        let noun = currentAccount?.kind.containerNoun ?? "container"
        containersGroup.title = noun.capitalized + "s"
        rebuildGroups()
    }

    @objc private func favoritesChanged() {
        rebuildGroups()
    }

    private func rebuildGroups() {
        favoritesGroup.children = FavoritesStore.shared.favorites.map(SidebarFavoriteNode.init)

        // Preserve the selected container across a reload, so adding a favorite does
        // not quietly move the user somewhere else.
        let selectedContainer = (outlineView.item(atRow: outlineView.selectedRow) as? SidebarContainerNode)?.container

        groups = favoritesGroup.children.isEmpty ? [containersGroup] : [favoritesGroup, containersGroup]

        suppressSelectionCallback = true
        outlineView.reloadData()
        groups.forEach { outlineView.expandItem($0) }
        if let selectedContainer,
           let node = containersGroup.children
               .compactMap({ $0 as? SidebarContainerNode })
               .first(where: { $0.container == selectedContainer }) {
            let row = outlineView.row(forItem: node)
            if row >= 0 { outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
        suppressSelectionCallback = false
    }

    /// Selects a container programmatically (used to auto-select the first one on
    /// connect); fires `onSelectContainer`.
    func select(_ container: StorageContainer) {
        guard let node = containersGroup.children
            .compactMap({ $0 as? SidebarContainerNode })
            .first(where: { $0.container == container }) else { return }
        outlineView.expandItem(containersGroup)
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: return groups.count
        case let group as SidebarGroup: return group.children.count
        default: return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let group = item as? SidebarGroup else { return groups[index] }
        return group.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SidebarGroup
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SidebarGroup
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SidebarContainerNode || item is SidebarFavoriteNode
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? SidebarGroup {
            return groupCell(text: group.title.uppercased())
        }
        if let node = item as? SidebarContainerNode {
            return containerCell(text: node.container.name)
        }
        if let node = item as? SidebarFavoriteNode {
            return favoriteCell(for: node.favorite)
        }
        return nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }
        let row = outlineView.selectedRow
        guard row >= 0 else { return }
        switch outlineView.item(atRow: row) {
        case let node as SidebarContainerNode:
            onSelectContainer?(node.container)
        case let node as SidebarFavoriteNode:
            onSelectFavorite?(node.favorite)
        default:
            break
        }
    }

    // MARK: - Drag out

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        if let node = item as? SidebarFavoriteNode {
            // Carries its own id so a drop back inside Favorites reorders.
            return LocationDrag(
                account: node.favorite.account,
                location: node.favorite.location,
                favoriteID: node.favorite.id
            ).pasteboardItem()
        }
        if let node = item as? SidebarContainerNode, let account = currentAccount {
            return LocationDrag(
                account: account,
                location: BrowserLocation(container: node.container.name, prefix: "")
            ).pasteboardItem()
        }
        return nil
    }

    // MARK: - Drop

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        // Files onto a saved place: upload there. Only "on" a row, and only for the
        // account we are actually connected to.
        if let urls = fileURLs(on: info.draggingPasteboard), !urls.isEmpty {
            guard index == NSOutlineViewDropOnItemIndex,
                  let node = item as? SidebarFavoriteNode,
                  node.favorite.account == currentAccount else { return [] }
            return .copy
        }

        guard let drag = LocationDrag.read(from: info.draggingPasteboard) else { return [] }

        // A place, dropped anywhere in (or on) the Favorites section.
        let intoFavorites = (item as? SidebarGroup)?.kind == .favorites
            || item is SidebarFavoriteNode
            || item == nil
        guard intoFavorites else { return [] }

        // Reordering an existing favorite needs a gap to land in, not a row to land on.
        if drag.favoriteID != nil {
            guard index != NSOutlineViewDropOnItemIndex else { return [] }
            outlineView.setDropItem(favoritesGroup, dropChildIndex: index)
            return .move
        }

        if FavoritesStore.shared.contains(account: drag.account, location: drag.location) { return [] }
        outlineView.setDropItem(favoritesGroup, dropChildIndex: index)
        return .copy
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        if let urls = fileURLs(on: info.draggingPasteboard), !urls.isEmpty,
           let node = item as? SidebarFavoriteNode {
            onDropFiles?(urls, node.favorite)
            return true
        }

        guard let drag = LocationDrag.read(from: info.draggingPasteboard) else { return false }

        if let id = drag.favoriteID {
            FavoritesStore.shared.move(id: id, to: index < 0 ? FavoritesStore.shared.favorites.count : index)
            return true
        }

        let favorite = Favorite(account: drag.account, location: drag.location)
        return FavoritesStore.shared.add(favorite, at: index < 0 ? nil : index)
    }

    private func fileURLs(on pasteboard: NSPasteboard) -> [URL]? {
        pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
    }

    // MARK: - Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let rename = NSMenuItem(title: "Rename", action: #selector(renameClickedFavorite(_:)), keyEquivalent: "")
        rename.target = self
        let remove = NSMenuItem(title: "Remove from Sidebar", action: #selector(removeClickedFavorite(_:)), keyEquivalent: "")
        remove.target = self
        menu.addItem(rename)
        menu.addItem(remove)
        return menu
    }

    private func clickedFavorite() -> Favorite? {
        let row = outlineView.clickedRow
        guard row >= 0 else { return nil }
        return (outlineView.item(atRow: row) as? SidebarFavoriteNode)?.favorite
    }

    @objc private func renameClickedFavorite(_ sender: Any?) {
        guard outlineView.clickedRow >= 0 else { return }
        beginRenaming(row: outlineView.clickedRow)
    }

    @objc private func removeClickedFavorite(_ sender: Any?) {
        guard let favorite = clickedFavorite() else { return }
        FavoritesStore.shared.remove(id: favorite.id)
    }

    // MARK: - Renaming

    private func beginRenamingSelectedFavorite() {
        let row = outlineView.selectedRow
        guard row >= 0, outlineView.item(atRow: row) is SidebarFavoriteNode else { return }
        beginRenaming(row: row)
    }

    private func beginRenaming(row: Int) {
        guard outlineView.item(atRow: row) is SidebarFavoriteNode else { return }
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    // MARK: - Cells

    private func groupCell(text: String) -> NSTableCellView {
        let cell = makeCell(identifier: "group")
        cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
        cell.textField?.textColor = .secondaryLabelColor
        cell.textField?.stringValue = text
        cell.textField?.isEditable = false
        cell.imageView?.isHidden = true
        return cell
    }

    private func containerCell(text: String) -> NSTableCellView {
        let cell = makeCell(identifier: "container")
        cell.textField?.font = .systemFont(ofSize: 13)
        cell.textField?.textColor = .labelColor
        cell.textField?.stringValue = text
        cell.textField?.isEditable = false
        cell.imageView?.isHidden = false
        cell.imageView?.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "Container")
        cell.imageView?.contentTintColor = .secondaryLabelColor
        return cell
    }

    private func favoriteCell(for favorite: Favorite) -> NSTableCellView {
        let cell = makeCell(identifier: "favorite")
        cell.textField?.font = .systemFont(ofSize: 13)
        cell.textField?.textColor = .labelColor
        cell.textField?.stringValue = favorite.displayName
        // Renameable in place, the way Finder's sidebar is.
        cell.textField?.isEditable = true
        cell.textField?.delegate = self
        cell.imageView?.isHidden = false
        // A whole container keeps the box icon it has in the list below; a folder
        // inside one gets the real Finder folder.
        if favorite.isContainerRoot {
            cell.imageView?.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "Container")
            cell.imageView?.contentTintColor = .secondaryLabelColor
        } else {
            let icon = NSWorkspace.shared.icon(for: .folder)
            icon.size = NSSize(width: 16, height: 16)
            cell.imageView?.image = icon
            cell.imageView?.contentTintColor = nil
        }
        cell.toolTip = "\(favorite.account) — \(favorite.location.path)"
        return cell
    }

    private func makeCell(identifier: String) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier(identifier)
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            return reused
        }

        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setContentHuggingPriority(.required, for: .horizontal)

        let cell = NSTableCellView()
        cell.identifier = id
        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.textField = textField
        cell.imageView = imageView

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - NSMenuDelegate

extension ContainerSidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // The rename/remove pair only means anything on a saved place.
        let isFavorite = clickedFavorite() != nil
        menu.items.forEach { $0.isEnabled = isFavorite }
    }
}

// MARK: - NSTextFieldDelegate (inline rename)

extension ContainerSidebarViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = outlineView.row(for: field)
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? SidebarFavoriteNode else { return }
        FavoritesStore.shared.rename(id: node.favorite.id, to: field.stringValue)
    }
}
