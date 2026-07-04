import AppKit

/// Reference-type outline nodes so NSOutlineView has stable item identity.
private final class SidebarGroup: NSObject {
    let title: String
    var containers: [SidebarContainerNode]
    init(title: String, containers: [SidebarContainerNode]) {
        self.title = title
        self.containers = containers
    }
}

private final class SidebarContainerNode: NSObject {
    let container: StorageContainer
    init(_ container: StorageContainer) { self.container = container }
}

/// Source-list sidebar listing the connected account's containers.
@MainActor
final class ContainerSidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    var onSelectContainer: ((StorageContainer) -> Void)?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let group = SidebarGroup(title: "Containers", containers: [])
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

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true

        view = scrollView
    }

    func setContainers(_ containers: [StorageContainer]) {
        group.containers = containers.map(SidebarContainerNode.init)
        outlineView.reloadData()
        outlineView.expandItem(group)
    }

    /// Selects a container programmatically (used to auto-select the first one on
    /// connect); fires `onSelectContainer`.
    func select(_ container: StorageContainer) {
        guard let node = group.containers.first(where: { $0.container == container }) else { return }
        outlineView.expandItem(group)
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: return 1
        case is SidebarGroup: return group.containers.count
        default: return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return group }
        return group.containers[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SidebarGroup
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SidebarGroup
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SidebarContainerNode
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? SidebarGroup {
            return groupCell(text: group.title.uppercased())
        }
        if let node = item as? SidebarContainerNode {
            return containerCell(text: node.container.name)
        }
        return nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? SidebarContainerNode else { return }
        onSelectContainer?(node.container)
    }

    // MARK: - Cells

    private func groupCell(text: String) -> NSTableCellView {
        let cell = makeCell(identifier: "group")
        cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
        cell.textField?.textColor = .secondaryLabelColor
        cell.textField?.stringValue = text
        cell.imageView?.isHidden = true
        return cell
    }

    private func containerCell(text: String) -> NSTableCellView {
        let cell = makeCell(identifier: "container")
        cell.textField?.font = .systemFont(ofSize: 13)
        cell.textField?.textColor = .labelColor
        cell.textField?.stringValue = text
        cell.imageView?.isHidden = false
        cell.imageView?.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "Container")
        cell.imageView?.contentTintColor = .secondaryLabelColor
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
