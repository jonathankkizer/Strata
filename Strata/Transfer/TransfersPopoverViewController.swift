import AppKit

/// The transfers list shown in a popover from the toolbar. Rows show real progress,
/// the emitted `data.api` as a badge, and a stop/retry control. Observes the queue
/// to reload on structural changes and update progress bars in place on ticks.
@MainActor
final class TransfersPopoverViewController: NSViewController {

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No transfers")
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let rowHeight: CGFloat = 66
    private let contentWidth: CGFloat = 380

    private var transfers: [TransferItem] { TransferQueue.shared.transfers }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 180))

        let title = NSTextField(labelWithString: "Transfers")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        clearButton.bezelStyle = .accessoryBarAction
        clearButton.controlSize = .small
        clearButton.target = self
        clearButton.action = #selector(clearFinished)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transfer"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.rowHeight = rowHeight
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.intercellSpacing = NSSize(width: 0, height: 0)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(title)
        view.addSubview(clearButton)
        view.addSubview(separator)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),

            clearButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            clearButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            separator.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(reload), name: .transferQueueDidChange, object: nil)
        center.addObserver(self, selector: #selector(updateVisibleProgress), name: .transferQueueProgress, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Updating

    @objc private func reload() {
        tableView.reloadData()
        let count = transfers.count
        emptyLabel.isHidden = count > 0
        clearButton.isEnabled = transfers.contains { !$0.isActive }

        let listHeight = min(CGFloat(max(count, 1)) * rowHeight, 400)
        preferredContentSize = NSSize(width: contentWidth, height: 40 + (count == 0 ? 80 : listHeight))
    }

    @objc private func updateVisibleProgress() {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.length > 0 else { return }
        for row in range.location..<(range.location + range.length) where row < transfers.count {
            if let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TransferRowView {
                view.update(with: transfers[row])
            }
        }
    }

    @objc private func clearFinished() {
        TransferQueue.shared.clearFinished()
    }
}

extension TransfersPopoverViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { transfers.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("TransferRow")
        let rowView = (tableView.makeView(withIdentifier: id, owner: self) as? TransferRowView) ?? {
            let view = TransferRowView()
            view.identifier = id
            return view
        }()
        let item = transfers[row]
        rowView.update(with: item)
        rowView.onAction = {
            if item.isActive {
                TransferQueue.shared.cancel(item)
            } else if item.canRevealInFinder {
                // Safari's downloads list: the finished-row button reveals the file.
                NSWorkspace.shared.activateFileViewerSelecting([item.localURL])
            } else if item.isRetryable {
                TransferQueue.shared.retry(item)
            }
        }
        return rowView
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}
