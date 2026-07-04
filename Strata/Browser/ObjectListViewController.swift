import AppKit

/// The main browse surface: a clickable path bar, a sortable table of folders and
/// blobs for the current location, and loading/empty/error states. Owns its own
/// async loading against the provider.
@MainActor
final class ObjectListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    var provider: (any StorageProvider)?

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
    private let messageLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    private var items: [StorageObject] = []
    private var loadToken = 0

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
        configureOverlays()

        view.addSubview(pathControl)
        view.addSubview(scrollView)
        view.addSubview(messageLabel)
        view.addSubview(spinner)

        pathControl.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            pathControl.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            pathControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            pathControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: pathControl.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            messageLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),

            spinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        showMessage("Connect to a storage account to begin.")
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
        addColumn(.name, title: "Name", width: 320, minWidth: 160)
        addColumn(.size, title: "Size", width: 90, minWidth: 60, alignment: .right)
        addColumn(.tier, title: "Tier", width: 70, minWidth: 50)
        addColumn(.modified, title: "Date Modified", width: 170, minWidth: 120)
        addColumn(.kind, title: "Content Type", width: 170, minWidth: 100)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .inset
        tableView.rowSizeStyle = .default
        tableView.allowsMultipleSelection = true
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.target = self
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
    }

    private func addColumn(_ column: Column, title: String, width: CGFloat, minWidth: CGFloat, alignment: NSTextAlignment = .left) {
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

    private func configureOverlays() {
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
    }

    // MARK: - Loading

    func reload() {
        guard let provider, let location else { return }

        loadToken += 1
        let token = loadToken
        clearMessage()
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
            showMessage("This location is empty.")
        } else {
            clearMessage()
        }
    }

    private func present(_ error: Error) {
        if case StorageProviderError.dataPlaneForbidden(let account) = error {
            showMessage("Authenticated, but this identity lacks a “Storage Blob Data” role on “\(account).”\n\nGrant Storage Blob Data Reader or Contributor to browse blob data — management roles (Owner/Contributor/Reader) don’t grant data-plane access.")
        } else if case StorageProviderError.unauthorized = error {
            showMessage("Not authorized. Your token may have expired — try reconnecting.")
        } else {
            showMessage("Couldn’t load this location.\n\n\(error.localizedDescription)")
        }
    }

    // MARK: - Message state

    func showMessage(_ text: String) {
        messageLabel.stringValue = text
        messageLabel.isHidden = false
    }

    private func clearMessage() {
        messageLabel.isHidden = true
        messageLabel.stringValue = ""
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
            let symbol = item.isPrefix ? "folder.fill" : "doc"
            cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            cell.imageView?.contentTintColor = item.isPrefix ? .controlAccentColor : .secondaryLabelColor
            return cell
        case .size:
            return textCell(item.isPrefix ? "—" : byteFormatter.string(fromByteCount: item.size), alignment: .right)
        case .tier:
            return textCell(item.isPrefix ? "" : (item.storageClass ?? "—"))
        case .modified:
            return textCell(item.lastModified.map { dateFormatter.string(from: $0) } ?? "")
        case .kind:
            return textCell(item.isPrefix ? "Folder" : (item.contentType ?? "—"))
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
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
