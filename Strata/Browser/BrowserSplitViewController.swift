import AppKit

/// Hosts the container sidebar, object list, and inspector, and coordinates between
/// them. Owns the connected provider and the Connect / Refresh / Upload / Inspector
/// actions (reached from the menu bar and toolbar via the responder chain).
@MainActor
final class BrowserSplitViewController: NSSplitViewController, NSToolbarItemValidation {

    let sidebar = ContainerSidebarViewController()
    let content = BrowserContentViewController()
    let inspector = InspectorViewController()

    /// List/Columns switcher; the window controller hosts it in the toolbar.
    let browseModeControl = NSSegmentedControl(
        images: [
            NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List") ?? NSImage(),
            NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Columns") ?? NSImage(),
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    private var provider: (any StorageProvider)?
    private var currentContainerName: String?
    private var refreshedCompletions = Set<UUID>()

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 400
        addSplitViewItem(contentItem)

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 380
        inspectorItem.canCollapse = true
        // Keep the window fixed and resize the center pane when the inspector
        // toggles (Xcode-style), rather than growing/shrinking the whole window.
        inspectorItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        // Hidden by default; the last shown/hidden choice is restored across launches.
        inspectorItem.isCollapsed = !StrataDefaults.inspectorVisible
        addSplitViewItem(inspectorItem)

        sidebar.onSelectContainer = { [weak self] container in
            guard let self, let provider = self.provider else { return }
            self.currentContainerName = container.name
            self.content.provider = provider
            self.content.location = BrowserLocation(container: container.name, prefix: "")
        }

        content.onSelectionChange = { [weak self] object in
            guard let self else { return }
            self.inspector.present(object: object, provider: self.provider, containerName: self.currentContainerName)
        }

        content.onDropFiles = { [weak self] urls in
            guard let self, self.provider != nil, let location = self.content.location else { return }
            self.startUpload(sources: urls, to: location)
        }

        browseModeControl.selectedSegment = content.mode.rawValue
        browseModeControl.target = self
        browseModeControl.action = #selector(switchBrowseMode(_:))

        NotificationCenter.default.addObserver(self, selector: #selector(transferQueueChanged), name: .transferQueueDidChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Actions

    @objc func connectAzureStorageAccount(_ sender: Any?) {
        // The account picker enumerates via the management plane, which is a
        // different token audience than the blob data plane we browse with.
        let managementToken = AzureCLITokenProvider(
            configuration: .init(resource: AzureAuth.managementResource)
        )
        let management = AzureManagementClient(tokenSource: managementToken)

        let picker = ConnectAccountViewController(
            loader: { try await management.listAllStorageAccounts() },
            onConnect: { [weak self] account in self?.connect(account: account) },
            onCancel: {}
        )
        presentAsSheet(picker)
    }

    @objc func refreshListing(_ sender: Any?) {
        content.reload()
    }

    @objc func switchBrowseMode(_ sender: NSSegmentedControl) {
        setBrowseMode(BrowseMode(rawValue: sender.selectedSegment) ?? .list)
    }

    @objc func showAsList(_ sender: Any?) { setBrowseMode(.list) }
    @objc func showAsColumns(_ sender: Any?) { setBrowseMode(.columns) }

    private func setBrowseMode(_ mode: BrowseMode) {
        content.mode = mode
        browseModeControl.selectedSegment = mode.rawValue
    }

    @objc func toggleObjectInspector(_ sender: Any?) {
        guard let item = splitViewItems.last, item.behavior == .inspector else { return }
        item.animator().isCollapsed.toggle()
        StrataDefaults.inspectorVisible = !item.isCollapsed
    }

    @objc func uploadFiles(_ sender: Any?) {
        guard let window = view.window, provider != nil, let location = content.location else {
            NSSound.beep()
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        let destination = location.prefix.isEmpty ? location.container : "\(location.container)/\(location.prefix)"
        panel.message = "Choose files or folders to upload to \(destination)"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            self?.startUpload(sources: panel.urls, to: location)
        }
    }

    // Enable the actions only when they make sense.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.action {
        case #selector(uploadFiles(_:)):
            return provider != nil && content.location != nil
        case #selector(refreshListing(_:)):
            return provider != nil
        default:
            return true
        }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(navigateToEnclosingFolder(_:)):
            return content.canNavigateUp
        case #selector(openSelection(_:)):
            return provider != nil
        case #selector(NSSplitViewController.toggleSidebar(_:)):
            if let menuItem = item as? NSMenuItem {
                let collapsed = splitViewItems.first?.isCollapsed ?? false
                menuItem.title = collapsed ? "Show Sidebar" : "Hide Sidebar"
            }
            return true
        case #selector(refreshListing(_:)):
            return provider != nil
        case #selector(showAsList(_:)):
            (item as? NSMenuItem)?.state = content.mode == .list ? .on : .off
            return true
        case #selector(showAsColumns(_:)):
            (item as? NSMenuItem)?.state = content.mode == .columns ? .on : .off
            return true
        case #selector(uploadFiles(_:)):
            return provider != nil && content.location != nil
        case #selector(toggleObjectInspector(_:)):
            if let menuItem = item as? NSMenuItem {
                let collapsed = (splitViewItems.last?.isCollapsed ?? true)
                menuItem.title = collapsed ? "Show Inspector" : "Hide Inspector"
            }
            return true
        case #selector(connectAzureStorageAccount(_:)):
            return true
        default:
            return true
        }
    }

    // MARK: - Upload

    private func startUpload(sources urls: [URL], to location: BrowserLocation) {
        Task { @MainActor in
            let prefix = location.prefix
            let planned = await Task.detached(priority: .userInitiated) {
                UploadPlanning.expand(urls: urls, prefix: prefix)
            }.value
            guard !planned.isEmpty else { NSSound.beep(); return }
            if StrataDefaults.askBeforeUploading {
                self.confirmUpload(planned, to: location)
            } else {
                self.performUploads(planned, location: location)
            }
        }
    }

    private func confirmUpload(_ planned: [PlannedUpload], to location: BrowserLocation) {
        guard let window = view.window else { return }

        // The differentiator, surfaced at the moment of action: show exactly which
        // event each upload will emit before the user commits.
        let alert = NSAlert()
        alert.messageText = planned.count == 1 ? "Upload “\(lastComponent(planned[0].key))”?" : "Upload \(planned.count) files?"
        let destination = location.prefix.isEmpty ? "\(location.container) (root)" : "\(location.container)/\(location.prefix)"
        var lines = planned.prefix(8).map { "• \(lastComponent($0.key)) — \($0.plan.predictedEventSummary)" }
        if planned.count > 8 { lines.append("…and \(planned.count - 8) more") }
        alert.informativeText = "Destination: \(destination)\n\n" + lines.joined(separator: "\n")
        alert.addButton(withTitle: "Upload")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performUploads(planned, location: location)
        }
    }

    private func performUploads(_ planned: [PlannedUpload], location: BrowserLocation) {
        guard let provider else { return }
        let container = StorageContainer(name: location.container)
        let destination = location.prefix.isEmpty ? location.container : "\(location.container)/\(location.prefix)"

        // Hand each file to the transfer queue; progress and errors surface there
        // rather than blocking the browser.
        for item in planned {
            TransferQueue.shared.enqueueUpload(
                fileURL: item.url,
                key: item.key,
                container: container,
                destination: destination,
                contentType: item.contentType,
                plan: item.plan,
                provider: provider
            )
        }
    }

    @objc func navigateToEnclosingFolder(_ sender: Any?) {
        content.navigateUp()
    }

    @objc func openSelection(_ sender: Any?) {
        content.openSelection()
    }

    /// Refresh the listing when a transfer finishes into the location on screen.
    @objc private func transferQueueChanged() {
        guard let location = content.location else { return }
        var shouldReload = false
        for transfer in TransferQueue.shared.transfers
        where transfer.state == .completed && !refreshedCompletions.contains(transfer.id) {
            refreshedCompletions.insert(transfer.id)
            if transfer.container.name == location.container, transfer.key.hasPrefix(location.prefix) {
                shouldReload = true
            }
        }
        if shouldReload { content.reload() }
    }

    private func lastComponent(_ key: String) -> String {
        var trimmed = key
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    // MARK: - Connect

    func connect(account: String) {
        let endpoint = AzureStorageEndpoint(account: account)
        let provider = AzureBlobProvider(
            displayName: account,
            endpoint: endpoint,
            tokenSource: AzureCLITokenProvider()
        )
        self.provider = provider
        content.provider = provider
        content.location = nil
        sidebar.setContainers([])
        content.showMessage("Loading containers from \(account)…")
        view.window?.title = account
        view.window?.subtitle = "Azure Blob Storage"

        Task { @MainActor in
            do {
                let containers = try await provider.listContainers()
                self.sidebar.setContainers(containers)
                if let first = containers.first {
                    self.sidebar.select(first)
                } else {
                    self.content.showMessage("No containers in “\(account).”")
                }
            } catch StorageProviderError.dataPlaneForbidden(let account) {
                self.content.showMessage("Authenticated, but this identity lacks a “Storage Blob Data” role on “\(account).”\n\nManagement roles (Owner/Contributor/Reader) don’t grant data-plane access.")
            } catch StorageProviderError.unauthorized {
                self.content.showMessage("Not authorized. Check that `az login` has a session for the account’s tenant.")
            } catch {
                self.content.showMessage("Couldn’t connect to “\(account).”\n\n\(error.localizedDescription)")
            }
        }
    }
}
