import AppKit

@MainActor
final class ConnectAccountViewController: NSViewController {

    /// Enumerates the accounts on offer for one provider. Async and throwing because
    /// both providers reach outside the app to answer — Azure to Resource Manager, S3
    /// to the AWS config on disk.
    typealias AccountLoader = @Sendable (ProviderKind) async throws -> [ConnectableAccount]

    private let loader: AccountLoader
    private let onConnect: (ProviderAccount) -> Void
    private let onCancel: () -> Void

    /// Which provider's accounts are listed. Switching reloads the list.
    private var selectedKind: ProviderKind

    // MARK: - UI

    private let bodyContainer = NSView()

    // Loading state
    private let loadingStack = NSStackView()
    private let spinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "")
    /// Switches which provider's accounts are listed.
    private let providerControl = NSSegmentedControl()

    // List state
    private let listStack = NSStackView()
    private let searchField = NSSearchField()
    private let tableScrollView = NSScrollView()
    private let tableView = NSTableView()

    // Fallback / error state
    private let fallbackStack = NSStackView()
    private let fallbackLabel = NSTextField(wrappingLabelWithString: "")

    // Manual entry — shown in all non-loading states
    private let manualField = NSTextField()

    // Bottom buttons
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)

    // MARK: - Data

    private enum State { case loading, list, fallback(String) }
    private var state: State = .loading

    /// Shared by the loading and list states so the sheet doesn't resize when the
    /// accounts land. The fallback state is genuinely terminal and sizes to itself.
    private static let listBodyHeight: CGFloat = 284

    private var allAccounts: [ConnectableAccount] = []
    private var filteredAccounts: [ConnectableAccount] = []

    private var hasStartedLoad = false
    /// Bumped per load so a slow answer for a provider the user has since switched away
    /// from is discarded rather than shown.
    private var loadToken = 0
    /// The single active height constraint on `bodyContainer`, swapped per state so
    /// they don't accumulate and conflict.
    private var bodyHeightConstraint: NSLayoutConstraint?

    // MARK: - Init

    init(loader: @escaping AccountLoader,
         initialKind: ProviderKind = .azureBlob,
         onConnect: @escaping (ProviderAccount) -> Void,
         onCancel: @escaping () -> Void) {
        self.loader = loader
        self.selectedKind = initialKind
        self.onConnect = onConnect
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - View

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 420))

        // Title
        let titleLabel = NSTextField(labelWithString: "Connect to Storage")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(labelWithString: "Choose an account from a provider you\u{2019}re already signed in to.")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        providerControl.segmentCount = Self.orderedKinds.count
        for (index, kind) in Self.orderedKinds.enumerated() {
            providerControl.setLabel(kind.displayName, forSegment: index)
        }
        providerControl.trackingMode = .selectOne
        providerControl.selectedSegment = Self.orderedKinds.firstIndex(of: selectedKind) ?? 0
        providerControl.target = self
        providerControl.action = #selector(providerChanged)
        providerControl.setAccessibilityLabel("Storage provider")
        providerControl.translatesAutoresizingMaskIntoConstraints = false

        let headerSep = NSBox()
        headerSep.boxType = .separator
        headerSep.translatesAutoresizingMaskIntoConstraints = false

        // Body container (swaps loading / list / fallback)
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false

        // Manual entry field
        manualField.placeholderString = "or enter an account name…"
        manualField.font = .systemFont(ofSize: 12)
        manualField.translatesAutoresizingMaskIntoConstraints = false
        manualField.target = self
        manualField.action = #selector(manualFieldChanged)
        (manualField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
        NotificationCenter.default.addObserver(self,
            selector: #selector(manualFieldChanged),
            name: NSControl.textDidChangeNotification,
            object: manualField)

        let footerSep = NSBox()
        footerSep.boxType = .separator
        footerSep.translatesAutoresizingMaskIntoConstraints = false

        // Buttons
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connectClicked)
        connectButton.isEnabled = false
        connectButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [cancelButton, connectButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        view.addSubview(providerControl)
        view.addSubview(headerSep)
        view.addSubview(bodyContainer)
        view.addSubview(manualField)
        view.addSubview(footerSep)
        view.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            providerControl.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 12),
            providerControl.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            providerControl.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            headerSep.topAnchor.constraint(equalTo: providerControl.bottomAnchor, constant: 14),
            headerSep.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerSep.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            bodyContainer.topAnchor.constraint(equalTo: headerSep.bottomAnchor),
            bodyContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            manualField.topAnchor.constraint(equalTo: bodyContainer.bottomAnchor, constant: 10),
            manualField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            manualField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            footerSep.topAnchor.constraint(equalTo: manualField.bottomAnchor, constant: 12),
            footerSep.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerSep.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            buttonRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            buttonRow.topAnchor.constraint(equalTo: footerSep.bottomAnchor, constant: 12),
            buttonRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

        buildLoadingState()
        buildListState()
        buildFallbackState()

        applyState(.loading)
    }

    // MARK: - State builders

    private func buildLoadingState() {
        spinner.style = .spinning
        spinner.translatesAutoresizingMaskIntoConstraints = false
        // A spinning indicator renders at its frame size, and the regular 16pt
        // control is lost in a body this tall. 32pt is the size Apple uses for a
        // sheet-filling wait.
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 32),
            spinner.heightAnchor.constraint(equalToConstant: 32),
        ])

        loadingLabel.font = .systemFont(ofSize: 12)
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false

        loadingStack.orientation = .vertical
        loadingStack.alignment = .centerX
        loadingStack.spacing = 12
        loadingStack.translatesAutoresizingMaskIntoConstraints = false
        // Added to the *center* gravity area, not as plain arranged subviews:
        // `embed` pins the stack to all four edges of the body, and a vertical
        // stack packs arranged subviews into the leading (top) area — which left
        // the spinner clinging to the separator with the rest of the body empty
        // beneath it. Gravity areas are how AppKit centres along the main axis.
        loadingStack.addView(spinner, in: .center)
        loadingStack.addView(loadingLabel, in: .center)
    }

    private func buildListState() {
        searchField.placeholderString = "Filter accounts…"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        (searchField.cell as? NSSearchFieldCell)?.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        NotificationCenter.default.addObserver(self,
            selector: #selector(searchChanged),
            name: NSControl.textDidChangeNotification,
            object: searchField)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("account"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = 52
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.drawsBackground = false
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false

        listStack.orientation = .vertical
        listStack.spacing = 8
        listStack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 0, right: 20)
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listStack.addArrangedSubview(searchField)
        listStack.addArrangedSubview(tableScrollView)

        tableScrollView.heightAnchor.constraint(equalToConstant: 220).isActive = true
    }

    private func buildFallbackState() {
        fallbackLabel.font = .systemFont(ofSize: 12)
        fallbackLabel.textColor = .secondaryLabelColor
        fallbackLabel.alignment = .center
        fallbackLabel.translatesAutoresizingMaskIntoConstraints = false

        fallbackStack.orientation = .vertical
        fallbackStack.alignment = .centerX
        fallbackStack.spacing = 6
        fallbackStack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        fallbackStack.translatesAutoresizingMaskIntoConstraints = false
        fallbackStack.addArrangedSubview(fallbackLabel)
    }

    // MARK: - State transitions

    private func applyState(_ newState: State) {
        state = newState

        // Remove any current body child
        bodyContainer.subviews.forEach { $0.removeFromSuperview() }

        switch newState {
        case .loading:
            spinner.startAnimation(nil)
            manualField.isHidden = true
            // Deliberately the same height as the list: the sheet is already on
            // screen while this resolves, and the common path resizing itself the
            // moment the accounts arrive reads as a glitch.
            embed(loadingStack, in: bodyContainer, height: Self.listBodyHeight)

        case .list:
            spinner.stopAnimation(nil)
            manualField.isHidden = false
            embed(listStack, in: bodyContainer, height: Self.listBodyHeight)

        case .fallback(let message):
            spinner.stopAnimation(nil)
            fallbackLabel.stringValue = message
            manualField.isHidden = false
            embed(fallbackStack, in: bodyContainer, height: 120)
        }

        updateConnectEnabled()
    }

    private func embed(_ child: NSView, in parent: NSView, height: CGFloat) {
        parent.addSubview(child)
        bodyHeightConstraint?.isActive = false
        let heightConstraint = parent.heightAnchor.constraint(equalToConstant: height)
        bodyHeightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            heightConstraint,
        ])
    }

    // MARK: - Loading

    /// The order the segmented control shows providers in.
    static let orderedKinds: [ProviderKind] = [.azureBlob, .s3]

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasStartedLoad else { return }
        hasStartedLoad = true
        reload()
    }

    @objc private func providerChanged() {
        let index = providerControl.selectedSegment
        guard index >= 0, index < Self.orderedKinds.count else { return }
        let kind = Self.orderedKinds[index]
        guard kind != selectedKind else { return }
        selectedKind = kind
        searchField.stringValue = ""
        manualField.stringValue = ""
        reload()
    }

    private func reload() {
        let kind = selectedKind
        loadingLabel.stringValue = Self.loadingMessage(for: kind)
        manualField.placeholderString = Self.manualEntryPlaceholder(for: kind)
        allAccounts = []
        filteredAccounts = []
        tableView.reloadData()
        applyState(.loading)
        loadToken += 1
        let token = loadToken

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let accounts = try await self.loader(kind)
                // The sheet may have been dismissed, or the user may have switched
                // provider while this was in flight — either way the answer is stale.
                guard self.view.window != nil, token == self.loadToken else { return }
                self.allAccounts = accounts
                self.filteredAccounts = accounts
                if accounts.isEmpty {
                    self.applyState(.fallback(Self.emptyMessage(for: kind)))
                } else {
                    self.applyState(.list)
                    self.tableView.reloadData()
                }
            } catch {
                guard self.view.window != nil, token == self.loadToken else { return }
                self.applyState(.fallback(self.fallbackMessage(for: error, kind: kind)))
            }
        }
    }

    private static func loadingMessage(for kind: ProviderKind) -> String {
        switch kind {
        case .azureBlob: return "Finding your storage accounts…"
        case .s3: return "Reading your AWS profiles…"
        }
    }

    private static func manualEntryPlaceholder(for kind: ProviderKind) -> String {
        switch kind {
        case .azureBlob: return "or enter an account name…"
        case .s3: return "or enter a profile name…"
        }
    }

    private static func emptyMessage(for kind: ProviderKind) -> String {
        switch kind {
        case .azureBlob:
            return "No storage accounts found under your Azure sign-in."
        case .s3:
            return "No AWS profiles found in ~/.aws. Run \u{2018}aws configure\u{2019} (or \u{2018}aws sso login\u{2019}) and try again."
        }
    }

    private func fallbackMessage(for error: Error, kind: ProviderKind) -> String {
        switch error {
        case AzureManagementError.managementForbidden:
            return "Your sign-in doesn\u{2019}t have directory/reader access to list accounts. You can still enter a name below."
        case AzureManagementError.unauthorized:
            return "Authentication failed. Check that \u{2018}az login\u{2019} is current, then try again."
        case AWSCLIError.binaryNotFound:
            return "The AWS CLI wasn\u{2019}t found. Install it (\u{2018}brew install awscli\u{2019}) or enter a profile name below."
        default:
            return "Couldn\u{2019}t list accounts. You can still enter a name below."
        }
    }

    // MARK: - Filtering

    @objc private func searchChanged() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            filteredAccounts = allAccounts
        } else {
            filteredAccounts = allAccounts.filter {
                $0.name.localizedCaseInsensitiveContains(query) ||
                $0.detail.localizedCaseInsensitiveContains(query)
            }
        }
        tableView.reloadData()
        updateConnectEnabled()
    }

    // MARK: - Connect / Cancel

    @objc private func manualFieldChanged() {
        updateConnectEnabled()
    }

    private func updateConnectEnabled() {
        switch state {
        case .loading:
            connectButton.isEnabled = false
        case .list, .fallback:
            let hasSelection = tableView.selectedRow >= 0
            let hasText = !manualField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
            connectButton.isEnabled = hasSelection || hasText
        }
    }

    private func resolvedAccountName() -> String? {
        if case .list = state, tableView.selectedRow >= 0 {
            return filteredAccounts[tableView.selectedRow].name
        }
        let text = manualField.stringValue.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    @objc private func connectClicked() {
        guard let name = resolvedAccountName() else { return }
        onConnect(ProviderAccount(kind: selectedKind, name: name))
        dismiss(nil)
    }

    @objc private func cancelClicked() {
        onCancel()
        dismiss(nil)
    }

    @objc private func rowDoubleClicked() {
        guard tableView.clickedRow >= 0, tableView.clickedRow < filteredAccounts.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: tableView.clickedRow), byExtendingSelection: false)
        connectClicked()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Table data source / delegate

extension ConnectAccountViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { filteredAccounts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("AccountRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? AccountRowView) ?? {
            let v = AccountRowView()
            v.identifier = id
            return v
        }()
        cell.configure(with: filteredAccounts[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateConnectEnabled()
    }
}

// MARK: - Row cell

@MainActor
private final class AccountRowView: NSTableCellView {

    private let nameLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")
    private let badgeBox = NSView()
    private let badgeLabel = NSTextField(labelWithString: "Data Lake")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        refreshBadgeColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBadgeColor()
    }

    private func build() {
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        badgeLabel.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeBox.wantsLayer = true
        badgeBox.layer?.cornerRadius = 4
        badgeBox.translatesAutoresizingMaskIntoConstraints = false
        badgeBox.addSubview(badgeLabel)
        badgeBox.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            badgeLabel.topAnchor.constraint(equalTo: badgeBox.topAnchor, constant: 1),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeBox.bottomAnchor, constant: -1),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeBox.leadingAnchor, constant: 5),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeBox.trailingAnchor, constant: -5),
        ])

        let titleRow = NSStackView(views: [nameLabel, badgeBox])
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .centerY

        secondaryLabel.font = .systemFont(ofSize: 11)
        secondaryLabel.textColor = .secondaryLabelColor
        secondaryLabel.lineBreakMode = .byTruncatingTail
        secondaryLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleRow, secondaryLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(with account: ConnectableAccount) {
        nameLabel.stringValue = account.name
        secondaryLabel.stringValue = account.detail
        badgeLabel.stringValue = account.badge ?? ""
        badgeBox.isHidden = account.badge == nil
    }

    private func refreshBadgeColor() {
        badgeBox.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }
}
