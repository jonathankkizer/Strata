import AppKit
import UniformTypeIdentifiers

/// Which browse layout the middle pane shows.
enum BrowseMode: Int, Sendable {
    case list = 0
    case columns = 1
}

/// Hosts both browse surfaces — the sortable list and the Finder-style Miller
/// columns — in the middle split pane, and presents a single interface to the
/// coordinator so switching modes is transparent. The two share the inspector
/// preview via `onSelectionChange`. Mode switches carry the current location
/// across so you stay where you were.
@MainActor
final class BrowserContentViewController: NSViewController {

    let list = ObjectListViewController()
    let columns = ColumnBrowserViewController()

    /// Finder-style path bar at the window bottom, shared by both views.
    private let pathBar = NSPathControl()
    private let pathBarSeparator = NSBox()
    private let folderPathIcon: NSImage = {
        let icon = NSWorkspace.shared.icon(for: .folder)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }()

    // MARK: - Shared inputs / outputs

    var provider: (any StorageProvider)? {
        didSet {
            list.provider = provider
            columns.provider = provider
        }
    }

    var onSelectionChange: ((StorageObject?) -> Void)? {
        didSet {
            list.onSelectionChange = onSelectionChange
            columns.onSelectionChange = onSelectionChange
        }
    }

    /// Drop-to-upload is wired for the list today; columns drop is a later refinement.
    var onDropFiles: (([URL]) -> Void)? {
        didSet { list.onDropFiles = onDropFiles }
    }

    // MARK: - Mode

    var mode: BrowseMode = .list {
        didSet {
            guard mode != oldValue else { return }
            applyMode(carrying: oldValue == .list ? list.location : columns.location)
        }
    }

    /// The active surface's current location.
    var location: BrowserLocation? {
        get { mode == .list ? list.location : columns.location }
        set { apply(location: newValue, to: mode) }
    }

    var canNavigateUp: Bool { mode == .list ? list.canNavigateUp : false }

    func navigateUp() {
        if mode == .list { list.navigateUp() }
    }

    func reload() {
        switch mode {
        case .list: list.reload()
        case .columns: columns.reload()
        }
    }

    func openSelection() {
        switch mode {
        case .list: list.openSelection()
        case .columns: columns.openSelection()
        }
    }

    func showMessage(_ text: String) {
        list.showMessage(text)
        columns.showMessage(text)
    }

    // MARK: - View

    override func loadView() {
        view = NSView()

        addChild(list)
        addChild(columns)

        // Content area (list / columns) fills above the path bar.
        let contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        for child in [list.view, columns.view] {
            child.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(child)
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                child.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
                child.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            ])
        }
        columns.view.isHidden = true   // list is the default surface

        configurePathBar()

        view.addSubview(contentContainer)
        view.addSubview(pathBarSeparator)
        view.addSubview(pathBar)

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: pathBarSeparator.topAnchor),

            pathBarSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pathBarSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pathBarSeparator.bottomAnchor.constraint(equalTo: pathBar.topAnchor),

            pathBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            pathBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            pathBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -3),
            pathBar.heightAnchor.constraint(equalToConstant: 20),
        ])

        // Both surfaces report location changes to the one shared path bar.
        list.onLocationChange = { [weak self] location in self?.updatePathBar(for: location) }
        columns.onLocationChange = { [weak self] location in self?.updatePathBar(for: location) }
    }

    private func configurePathBar() {
        pathBar.pathStyle = .standard
        pathBar.target = self
        pathBar.action = #selector(pathBarClicked(_:))
        pathBar.focusRingType = .none
        pathBar.font = .systemFont(ofSize: 11)
        pathBar.translatesAutoresizingMaskIntoConstraints = false

        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "Copy Path", action: #selector(copyPathBarPath(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        pathBar.menu = menu

        pathBarSeparator.boxType = .separator
        pathBarSeparator.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Path bar

    private func updatePathBar(for location: BrowserLocation?) {
        guard let location else {
            pathBar.pathItems = []
            return
        }
        var items: [NSPathControlItem] = []
        let root = NSPathControlItem()
        root.title = location.container
        root.image = folderPathIcon
        items.append(root)
        for segment in location.segments {
            let item = NSPathControlItem()
            item.title = segment
            item.image = folderPathIcon
            items.append(item)
        }
        pathBar.pathItems = items
    }

    @objc private func pathBarClicked(_ sender: NSPathControl) {
        guard let location = self.location, let clicked = sender.clickedPathItem,
              let index = sender.pathItems.firstIndex(of: clicked) else { return }
        // index 0 is the container root (empty prefix); index i keeps the first i segments.
        let newPrefix = index == 0 ? "" : location.segments[0..<index].map { $0 + "/" }.joined()
        guard newPrefix != location.prefix else { return }
        self.location = BrowserLocation(container: location.container, prefix: newPrefix)
    }

    /// Copy the full path (container/prefix…) up to the right-clicked segment, or the
    /// whole current path — Finder's "Copy as Pathname".
    @objc private func copyPathBarPath(_ sender: Any?) {
        guard let location = self.location else { return }
        let segments = location.segments
        let count: Int
        if let clicked = pathBar.clickedPathItem, let index = pathBar.pathItems.firstIndex(of: clicked) {
            count = index
        } else {
            count = segments.count
        }
        let path = ([location.container] + segments.prefix(count)).joined(separator: "/")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    // MARK: - Mode plumbing

    private func applyMode(carrying carried: BrowserLocation?) {
        list.view.isHidden = (mode != .list)
        columns.view.isHidden = (mode != .columns)
        apply(location: carried, to: mode)
    }

    private func apply(location: BrowserLocation?, to mode: BrowseMode) {
        switch mode {
        case .list:
            if list.location != location { list.location = location }
        case .columns:
            if let location {
                columns.show(location)
            } else {
                columns.showMessage("Select a container to begin.")
            }
        }
    }
}
