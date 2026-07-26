import AppKit

/// First-launch launcher window (the Xcode / Tower shape): who the app is on the
/// left, somewhere to go on the right.
///
/// Strata isn't document-based, so there is no Open Recent to list. The equivalent —
/// and the only list the app actually keeps — is Favorites, which already carries an
/// account per entry and so is genuinely a "pick up where you left off" list rather
/// than decoration.
@MainActor
final class WelcomeWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    /// Present the account picker in a fresh browser window.
    var onConnect: (() -> Void)?
    /// Open a browser window pointed at a saved place, reconnecting if it belongs to
    /// another account.
    var onOpenFavorite: ((Favorite) -> Void)?
    /// Reconnect to a known account without going through the picker.
    var onReconnect: ((ProviderAccount) -> Void)?

    private let favoritesTable = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyStateLabel = NSTextField(labelWithString: "No Saved Places")
    private let emptyStateHint = NSTextField(wrappingLabelWithString:
        "Folders you add to the sidebar with ⌃⌘T show up here, ready to open."
    )
    private let showOnLaunchCheckbox = NSButton(
        checkboxWithTitle: "Show this window when Strata launches",
        target: nil,
        action: nil
    )

    private var favorites: [Favorite] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // A launcher isn't a document window: nothing to minimise to, nothing to zoom.
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // Reshown on demand from the Window menu, so it must survive being closed.
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: nil)
        self.window = window

        configureContent()
        configureFooter()
        reloadFavorites()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(favoritesDidChange(_:)),
            name: .favoritesDidChange,
            object: nil
        )
        // Dismiss once a browser window takes over — the Mac convention for launcher
        // windows. Covers every path in, including ⌘N and the Window menu, not just
        // this window's own buttons.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(anyWindowBecameMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Content

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        let left = makeLeftColumn()
        let right = makeRightColumn()

        let columns = NSStackView(views: [left, right])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fill
        columns.spacing = 0
        columns.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(columns)

        NSLayoutConstraint.activate([
            columns.topAnchor.constraint(equalTo: contentView.topAnchor),
            columns.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            // Room for the footer row.
            columns.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -44),
            left.widthAnchor.constraint(equalToConstant: 350),
        ])
    }

    private func makeLeftColumn() -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(named: NSImage.applicationIconName) ?? NSImage(named: "AppIcon")
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 112),
            icon.heightAnchor.constraint(equalToConstant: 112),
        ])

        let title = NSTextField(labelWithString: "Welcome to Strata")
        title.font = .systemFont(ofSize: 26, weight: .bold)

        let version = UpdateCoordinator.currentVersionString() ?? "Development"
        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor

        // The one thing a first-run user has to know: Strata has no credentials of its
        // own and never will. If `az login` hasn't happened, connecting cannot work,
        // and saying so here beats an auth error later.
        let signInNote = NSTextField(wrappingLabelWithString:
            "Strata browses Azure Blob Storage using the Azure CLI's sign-in — run "
            + "az login once and Strata asks it for a fresh token each time. Nothing "
            + "is stored here."
        )
        signInNote.font = .systemFont(ofSize: 11)
        signInNote.textColor = .secondaryLabelColor
        signInNote.preferredMaxLayoutWidth = 278

        let identity = NSStackView(views: [title, versionLabel])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 2

        var buttons = [makeActionButton(
            title: "Connect to Azure Storage Account…",
            symbolName: "externaldrive.badge.plus",
            action: #selector(connectClicked(_:))
        )]
        buttons[0].keyEquivalent = "\r"

        // Only when reconnect-on-launch is off — otherwise this window isn't shown in
        // the first place, because a window has already gone and reconnected.
        if let account = StrataDefaults.lastAccount, !account.isEmpty {
            buttons.append(makeActionButton(
                title: "Reconnect to \(account.name)",
                symbolName: "arrow.clockwise",
                action: #selector(reconnectClicked(_:))
            ))
        }

        let actions = NSStackView(views: buttons)
        actions.orientation = .vertical
        actions.alignment = .leading
        actions.spacing = 10

        let stack = NSStackView(views: [icon, identity, signInNote, NSView(), actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 34, left: 36, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeActionButton(title: String, symbolName: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .regularSquare
        button.controlSize = .large
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 278),
            button.heightAnchor.constraint(equalToConstant: 36),
        ])
        return button
    }

    private func makeRightColumn() -> NSView {
        let heading = NSTextField(labelWithString: "Saved Places")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = .secondaryLabelColor

        favoritesTable.headerView = nil
        favoritesTable.backgroundColor = .clear
        favoritesTable.rowSizeStyle = .custom
        favoritesTable.rowHeight = 44
        favoritesTable.intercellSpacing = NSSize(width: 0, height: 2)
        favoritesTable.gridStyleMask = []
        favoritesTable.usesAlternatingRowBackgroundColors = false
        favoritesTable.style = .inset
        favoritesTable.target = self
        favoritesTable.doubleAction = #selector(openSelectedFavorite(_:))
        // Single click selects; only a double-click commits. Matches Open Recent lists.
        favoritesTable.action = nil
        favoritesTable.allowsEmptySelection = true
        favoritesTable.allowsMultipleSelection = false
        favoritesTable.dataSource = self
        favoritesTable.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("favorite"))
        column.resizingMask = .autoresizingMask
        favoritesTable.addTableColumn(column)

        scrollView.documentView = favoritesTable
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyStateLabel.font = .systemFont(ofSize: 14)
        emptyStateLabel.textColor = .tertiaryLabelColor
        emptyStateLabel.alignment = .center

        emptyStateHint.font = .systemFont(ofSize: 11)
        emptyStateHint.textColor = .tertiaryLabelColor
        emptyStateHint.alignment = .center
        emptyStateHint.preferredMaxLayoutWidth = 260

        let empty = NSStackView(views: [emptyStateLabel, emptyStateHint])
        empty.orientation = .vertical
        empty.alignment = .centerX
        empty.spacing = 6
        empty.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        container.addSubview(empty)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])

        let stack = NSStackView(views: [heading, container])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 46, left: 12, bottom: 24, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func configureFooter() {
        guard let contentView = window?.contentView else { return }

        showOnLaunchCheckbox.target = self
        showOnLaunchCheckbox.action = #selector(toggleShowOnLaunch(_:))
        showOnLaunchCheckbox.state = StrataDefaults.showWelcomeOnLaunch ? .on : .off
        showOnLaunchCheckbox.font = .systemFont(ofSize: 12)
        showOnLaunchCheckbox.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(showOnLaunchCheckbox)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(separator)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            separator.bottomAnchor.constraint(equalTo: showOnLaunchCheckbox.topAnchor, constant: -10),

            showOnLaunchCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 36),
            showOnLaunchCheckbox.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
        ])
    }

    // MARK: - Favorites list

    private func reloadFavorites() {
        favorites = FavoritesStore.shared.favorites
        favoritesTable.reloadData()
        let isEmpty = favorites.isEmpty
        emptyStateLabel.isHidden = !isEmpty
        emptyStateHint.isHidden = !isEmpty
        scrollView.isHidden = isEmpty
    }

    @objc private func favoritesDidChange(_ notification: Notification) {
        reloadFavorites()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { favorites.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let favorite = favorites[row]

        let icon = NSImageView()
        icon.image = BlobIcon.folder
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
        ])

        let title = NSTextField(labelWithString: favorite.displayName)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.cell?.usesSingleLineMode = true

        // The account matters here in a way it doesn't in the sidebar: this list can
        // span accounts, and opening one may mean reconnecting.
        // The account is qualified with its cloud: this list spans providers, and two
        // of them can each have an account called "prod".
        let subtitle = NSTextField(labelWithString: "\(favorite.account.qualifiedName) — \(favorite.location.path)")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.cell?.usesSingleLineMode = true

        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let stack = NSStackView(views: [icon, text])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("favorite-row")
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: cell.topAnchor),
            stack.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
        ])
        return cell
    }

    // MARK: - Actions

    @objc private func connectClicked(_ sender: Any?) {
        onConnect?()
    }

    @objc private func reconnectClicked(_ sender: Any?) {
        guard let account = StrataDefaults.lastAccount, !account.isEmpty else {
            NSSound.beep()
            return
        }
        onReconnect?(account)
    }

    @objc private func openSelectedFavorite(_ sender: Any?) {
        let row = favoritesTable.clickedRow >= 0 ? favoritesTable.clickedRow : favoritesTable.selectedRow
        guard row >= 0, row < favorites.count else { return }
        onOpenFavorite?(favorites[row])
    }

    @objc private func toggleShowOnLaunch(_ sender: NSButton) {
        StrataDefaults.showWelcomeOnLaunch = sender.state == .on
    }

    /// Keeps the checkbox honest if the preference is changed in Settings while this
    /// window is open.
    func syncShowOnLaunchCheckbox() {
        showOnLaunchCheckbox.state = StrataDefaults.showWelcomeOnLaunch ? .on : .off
    }

    @objc private func anyWindowBecameMain(_ notification: Notification) {
        guard let window, window.isVisible else { return }
        guard let other = notification.object as? NSWindow, other !== window else { return }
        // Only a real browser window dismisses this — not the account picker sheet,
        // not Settings, not an alert.
        guard other.contentViewController is BrowserSplitViewController else { return }
        window.performClose(nil)
    }
}
