import AppKit

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

    func showMessage(_ text: String) {
        list.showMessage(text)
        columns.showMessage(text)
    }

    // MARK: - View

    override func loadView() {
        view = NSView()

        addChild(list)
        addChild(columns)

        for child in [list.view, columns.view] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: view.topAnchor),
                child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }

        columns.view.isHidden = true   // list is the default surface
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
