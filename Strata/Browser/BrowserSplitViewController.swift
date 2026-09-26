import AppKit
import QuickLookUI

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

    /// Whether this window restores the last browsed folder on launch. Only the first
    /// window does; ⌘N should open a fresh view of the account, not a second copy of
    /// wherever you were.
    var restoresLastLocation = false

    private var provider: (any StorageProvider)?
    private var currentContainerName: String?
    private var refreshedCompletions = Set<UUID>()
    private let quickLook = QuickLookController()

    private var history = BrowserHistory()
    /// Set while Back/Forward is driving the location, so the resulting change isn't
    /// recorded as a new visit and doesn't truncate the forward stack.
    private var isNavigatingHistory = false
    /// A location to land on once the account's containers have loaded.
    private var pendingRestoreLocation: BrowserLocation?
    private var hasAttemptedReconnect = false

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

        // Persist the sidebar and inspector widths across launches. Shared by every
        // browser window, which is what Finder does too.
        splitView.autosaveName = "StrataBrowserSplit"

        sidebar.onSelectContainer = { [weak self] container in
            guard let self, let provider = self.provider else { return }
            self.currentContainerName = container.name
            self.content.provider = provider
            // Restoring the last folder happens here rather than after the container
            // loads, so the listing is fetched once instead of twice.
            if let restore = self.pendingRestoreLocation, restore.container == container.name {
                self.pendingRestoreLocation = nil
                self.content.location = restore
            } else {
                self.content.location = BrowserLocation(container: container.name, prefix: "")
            }
        }

        content.onSelectionChange = { [weak self] objects in
            guard let self else { return }
            self.inspector.present(objects: objects, provider: self.provider, containerName: self.currentContainerName)
            // Finder keeps the open Quick Look panel following the selection.
            self.refreshQuickLookForSelection()
        }

        quickLook.sourceFrameProvider = { [weak self] in self?.content.selectedRowScreenRect }
        quickLook.keyForwarder = { [weak self] event in self?.content.forwardKeyDown(event) }

        sidebar.onSelectFavorite = { [weak self] favorite in
            self?.goToFavorite(favorite)
        }
        sidebar.onDropFiles = { [weak self] urls, favorite in
            // Dropping files on a saved place uploads them there, wherever the
            // browser happens to be pointed.
            self?.startUpload(sources: urls, to: favorite.location)
        }

        content.onDropFiles = { [weak self] urls, location in
            guard let self, self.provider != nil else { return }
            self.startUpload(sources: urls, to: location)
        }

        content.onLocationChange = { [weak self] location in
            guard let self else { return }
            // Finder titles a window with the folder you're looking at; track it so
            // the Window menu lists distinguishable entries.
            self.updateWindowTitle(for: location)

            guard let location else { return }
            // Back/Forward set the location themselves; recording that would both
            // duplicate the entry and wipe the forward stack. Arrowing between open
            // columns is a focus move, not a visit, so it stays out of history too.
            if !self.isNavigatingHistory, !self.content.isFocusMove {
                self.history.record(location)
            }
            StrataDefaults.lastLocation = location
        }

        browseModeControl.target = self
        browseModeControl.action = #selector(switchBrowseMode(_:))
        browseModeControl.setAccessibilityLabel("Browse layout")
        browseModeControl.setToolTip("View as List", forSegment: BrowseMode.list.rawValue)
        browseModeControl.setToolTip("View as Columns", forSegment: BrowseMode.columns.rawValue)
        inspector.view.setAccessibilityLabel("Inspector")
        // Restore the last-used browse layout (List/Columns) from the previous launch.
        setBrowseMode(BrowseMode(rawValue: StrataDefaults.browseMode) ?? .list)

        NotificationCenter.default.addObserver(self, selector: #selector(transferQueueChanged), name: .transferQueueDidChange, object: nil)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Deferred to here rather than viewDidLoad because connecting updates the
        // window title, and there is no window yet at load time.
        guard !hasAttemptedReconnect else { return }
        hasAttemptedReconnect = true
        reconnectToLastAccount()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Reconnect

    /// Reopens the last account on launch. Credentials are the `az` CLI's problem, so
    /// this is just a name and a fresh token request — if the CLI session has expired
    /// the browse surface reports it the same way it would after any other failure.
    private func reconnectToLastAccount() {
        guard StrataDefaults.reconnectOnLaunch, let account = StrataDefaults.lastAccount else { return }
        if restoresLastLocation, let location = StrataDefaults.lastLocation {
            pendingRestoreLocation = location
        }
        connect(account: account)
    }

    // MARK: - Actions

    @objc func connectStorageAccount(_ sender: Any?) {
        // Azure enumerates via the management plane, which is a different token
        // audience than the blob data plane we browse with.
        let managementToken = AzureCLITokenProvider(
            configuration: .init(resource: AzureAuth.managementResource)
        )
        let management = AzureManagementClient(tokenSource: managementToken)

        let picker = ConnectAccountViewController(
            loader: { kind in
                switch kind {
                case .azureBlob:
                    return try await management.listAllStorageAccounts().map(ConnectableAccount.init(azure:))
                case .s3:
                    // Profiles come off disk, so this is effectively instant — but it
                    // stays async because the Azure side isn't and the picker shouldn't
                    // care which it's asking.
                    return AWSConfigFile.profilesOnDisk().map(ConnectableAccount.init(awsProfile:))
                }
            },
            // Opens on whichever provider this window is already connected to, so
            // reconnecting elsewhere in the same cloud doesn't start with a switch.
            initialKind: account?.kind ?? .azureBlob,
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
        StrataDefaults.browseMode = mode.rawValue
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
        case #selector(sortBy(_:)):
            if let menuItem = item as? NSMenuItem, let key = menuItem.representedObject as? SortKey {
                menuItem.state = content.sort.key == key ? .on : .off
            }
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
        case #selector(downloadSelection(_:)), #selector(downloadSelectionTo(_:)):
            return provider != nil && !content.downloadableSelection.isEmpty
        case #selector(deleteSelection(_:)):
            // Folders count here, unlike Download — deleting a prefix is meaningful even
            // though downloading one is not yet.
            return provider != nil && !content.selection.isEmpty
        case #selector(toggleQuickLook(_:)):
            if let menuItem = item as? NSMenuItem {
                menuItem.title = quickLook.isPreviewing ? "Close Quick Look" : "Quick Look"
            }
            // Closing only needs the panel to be open; opening needs a blob selected.
            return quickLook.isPreviewing || (provider != nil && !content.downloadableSelection.isEmpty)
        case #selector(toggleObjectInspector(_:)):
            if let menuItem = item as? NSMenuItem {
                let collapsed = (splitViewItems.last?.isCollapsed ?? true)
                menuItem.title = collapsed ? "Show Inspector" : "Hide Inspector"
            }
            return true
        case #selector(connectStorageAccount(_:)):
            return true
        case #selector(goBack(_:)):
            return history.canGoBack
        case #selector(goForward(_:)):
            return history.canGoForward
        case #selector(goToFolder(_:)):
            return provider != nil
        case #selector(paste(_:)):
            return provider != nil && content.location != nil && !Self.fileURLsOnPasteboard().isEmpty
        case #selector(addToSidebar(_:)):
            guard let account, let location = favoritableLocation() else { return false }
            // Disabled rather than silently making a second copy of the same place.
            return !FavoritesStore.shared.contains(account: account, location: location)
        default:
            return true
        }
    }

    // MARK: - Upload

    private func startUpload(sources urls: [URL], to location: BrowserLocation) {
        guard let provider else { NSSound.beep(); return }
        Task { @MainActor in
            let prefix = location.prefix
            // Resolved here, on the main actor, so the detached expansion captures a
            // plain value rather than reaching back for the provider.
            let target = UploadTarget.default(for: provider.kind)
            let planned = await Task.detached(priority: .userInitiated) {
                UploadPlanning.expand(urls: urls, prefix: prefix, target: target)
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

    // MARK: - Paste

    /// ⌘V with files on the pasteboard uploads them here — the mirror of dragging
    /// them in, and of Finder's own paste. Routed through exactly the same planning
    /// and queueing as a drop.
    @objc func paste(_ sender: Any?) {
        guard let location = content.location, provider != nil else { NSSound.beep(); return }
        let urls = Self.fileURLsOnPasteboard()
        guard !urls.isEmpty else { NSSound.beep(); return }
        startUpload(sources: urls, to: location)
    }

    private static func fileURLsOnPasteboard() -> [URL] {
        NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }

    // MARK: - Download

    /// Download the selection straight to the download folder — Safari's
    /// "Download Linked File". Honours the "Ask for each download" preference.
    @objc func downloadSelection(_ sender: Any?) {
        startDownload(askWhereToSave: StrataDefaults.askWhereToSaveDownloads)
    }

    /// Always ask where to put it — Safari's "Download Linked File As…".
    @objc func downloadSelectionTo(_ sender: Any?) {
        startDownload(askWhereToSave: true)
    }

    // MARK: - Delete

    /// ⌘⌫. Unlike Download, this acts on folders too: a folder is a prefix, and the
    /// sheet expands it before asking.
    @objc func deleteSelection(_ sender: Any?) {
        let selection = content.selection
        guard let provider, let containerName = content.selectedContainerName, !selection.isEmpty else {
            NSSound.beep()
            return
        }

        let sheet = DeleteConfirmationViewController(
            selection: selection,
            container: StorageContainer(name: containerName),
            provider: provider
        ) { [weak self] outcome in
            guard let self, case let .deleted(failures) = outcome else { return }
            // Refresh whatever the outcome: a partly-failed delete still removed things,
            // and a listing that still shows them is worse than the failure itself.
            self.content.reload()
            if !failures.isEmpty { self.reportDeletionFailures(failures) }
        }
        presentAsSheet(sheet)
    }

    private func reportDeletionFailures(_ failures: [DeletionFailure]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failures.count == 1
            ? "One object couldn\u{2019}t be deleted."
            : "\(failures.count) objects couldn\u{2019}t be deleted."
        // Name the keys rather than only counting them: which ones survived is the
        // thing the user has to act on. Capped, because a listing of hundreds in an
        // alert helps nobody.
        let named = failures.prefix(5).map { "\($0.key) — \($0.message)" }
        let more = failures.count > named.count ? "\n\u{2026}and \(failures.count - named.count) more." : ""
        alert.informativeText = named.joined(separator: "\n") + more
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func startDownload(askWhereToSave: Bool) {
        let objects = content.downloadableSelection
        guard let provider, let containerName = content.selectedContainerName, !objects.isEmpty else {
            NSSound.beep()
            return
        }
        let container = StorageContainer(name: containerName)

        guard askWhereToSave else {
            enqueueDownloads(objects, in: container, provider: provider, into: StrataDefaults.downloadDirectory)
            return
        }
        // One blob gets a save panel so the name can be edited; several get a folder
        // chooser, since a save panel can only name one file.
        if objects.count == 1 {
            presentSavePanel(for: objects[0], in: container, provider: provider)
        } else {
            presentFolderPanel(for: objects, in: container, provider: provider)
        }
    }

    private func presentSavePanel(for object: StorageObject, in container: StorageContainer, provider: any StorageProvider) {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.localFileName(for: object)
        panel.directoryURL = StrataDefaults.downloadDirectory
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = "Download from \(container.name)"
        // NSSavePanel handles the overwrite confirmation itself.
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            TransferQueue.shared.enqueueDownload(object: object, container: container, to: url, provider: provider)
        }
    }

    private func presentFolderPanel(for objects: [StorageObject], in container: StorageContainer, provider: any StorageProvider) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Download"
        panel.message = "Choose where to download \(objects.count) items"
        panel.directoryURL = StrataDefaults.downloadDirectory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let directory = panel.url else { return }
            self?.enqueueDownloads(objects, in: container, provider: provider, into: directory)
        }
    }

    /// Queues one download per blob, resolving name collisions Finder-style. Names
    /// claimed by any unfinished download — earlier in this batch or from another one
    /// still in the queue — count as taken, since those files aren't on disk to be
    /// found by `fileExists` yet.
    private func enqueueDownloads(
        _ objects: [StorageObject],
        in container: StorageContainer,
        provider: any StorageProvider,
        into directory: URL
    ) {
        let manager = FileManager.default
        var reserved = TransferQueue.shared.claimedDownloadPaths
        for object in objects {
            let url = DownloadPlanning.uniqueURL(
                fileName: Self.localFileName(for: object),
                in: directory,
                exists: { reserved.contains($0.standardizedFileURL.path) || manager.fileExists(atPath: $0.path) }
            )
            reserved.insert(url.standardizedFileURL.path)
            TransferQueue.shared.enqueueDownload(object: object, container: container, to: url, provider: provider)
        }
    }

    private static func localFileName(for object: StorageObject) -> String {
        DownloadPlanning.fileName(
            forKey: object.key,
            preferredExtension: BlobIcon.utType(for: object).preferredFilenameExtension
        )
    }

    // MARK: - Quick Look

    /// Space (or ⌘Y): preview the selection, or dismiss the panel if it is already
    /// up — the Finder's toggle.
    @objc func toggleQuickLook(_ sender: Any?) {
        if quickLook.isPreviewing {
            quickLook.close()
            return
        }
        guard let object = content.downloadableSelection.first,
              let provider,
              let containerName = content.selectedContainerName else {
            NSSound.beep()
            return
        }
        quickLook.preview(
            object: object,
            container: StorageContainer(name: containerName),
            provider: provider,
            account: provider.account.id,
            openingPanel: true
        )
    }

    /// Swap the open panel's content as the selection moves. Does nothing when the
    /// panel is closed, so ordinary browsing never triggers a fetch.
    private func refreshQuickLookForSelection() {
        guard quickLook.isPreviewing else { return }
        guard let object = content.downloadableSelection.first,
              let provider,
              let containerName = content.selectedContainerName else {
            quickLook.clear()
            return
        }
        quickLook.preview(
            object: object,
            container: StorageContainer(name: containerName),
            provider: provider,
            account: provider.account.id,
            openingPanel: false
        )
    }

    // MARK: - Window title

    /// The connected account, used as the window subtitle.
    private var account: ProviderAccount?

    /// Titles the window with the folder in view and subtitles it with the account
    /// and full path — so several open windows are told apart in the Window menu.
    private func updateWindowTitle(for location: BrowserLocation?) {
        guard let window = view.window else { return }
        guard let location else {
            window.title = account?.name ?? "Strata"
            // The provider stands in for a path before one exists — and now that there
            // can be more than one, it has to come from the connection rather than
            // being hardcoded to Azure.
            window.subtitle = account?.kind.displayName ?? ""
            return
        }
        window.title = location.segments.last ?? location.container
        let path = ([location.container] + location.segments).joined(separator: "/")
        window.subtitle = account.map { "\($0.name) — \(path)" } ?? path
    }

    // MARK: - Go

    /// ⌘[ — Safari/Finder Back.
    @objc func goBack(_ sender: Any?) {
        guard let location = history.goBack() else { NSSound.beep(); return }
        navigate(toHistory: location)
    }

    /// ⌘] — Forward.
    @objc func goForward(_ sender: Any?) {
        guard let location = history.goForward() else { NSSound.beep(); return }
        navigate(toHistory: location)
    }

    private func navigate(toHistory location: BrowserLocation) {
        isNavigatingHistory = true
        defer { isNavigatingHistory = false }
        // Moving between containers has to move the sidebar selection too, or the
        // sidebar would claim you are somewhere you are not.
        if location.container != currentContainerName {
            currentContainerName = location.container
            sidebar.select(StorageContainer(name: location.container))
        }
        content.location = location
    }

    /// ⇧⌘G — type a path to jump straight there.
    @objc func goToFolder(_ sender: Any?) {
        guard provider != nil else { NSSound.beep(); return }
        let sheet = GoToFolderViewController(
            initialPath: content.location?.path ?? "",
            onGo: { [weak self] location in self?.navigate(toTyped: location) }
        )
        presentAsSheet(sheet)
    }

    private func navigate(toTyped location: BrowserLocation) {
        currentContainerName = location.container
        // Route through the pending-restore hook so selecting the container lands on
        // the requested folder directly, instead of loading its root and then the
        // folder — two listings for one jump.
        pendingRestoreLocation = location
        sidebar.select(StorageContainer(name: location.container))
        if pendingRestoreLocation != nil {
            // The container isn't in the sidebar (not loaded, or gone); go anyway.
            pendingRestoreLocation = nil
            content.location = location
        }
    }

    // MARK: - Favorites

    /// ⌃⌘T — save the selected folder, or the folder in view when nothing is selected.
    /// Finder's command, shortcut, and fallback behaviour.
    @objc func addToSidebar(_ sender: Any?) {
        guard let account, let location = favoritableLocation() else {
            NSSound.beep()
            return
        }
        if !FavoritesStore.shared.add(Favorite(account: account, location: location)) {
            NSSound.beep()   // already saved
        }
    }

    /// The place ⌃⌘T would save: a selected folder wins over the folder in view.
    private func favoritableLocation() -> BrowserLocation? {
        if let folder = content.selectedFolder, let container = content.selectedContainerName {
            return BrowserLocation(container: container, prefix: folder.key)
        }
        return content.location
    }

    /// Go-menu entry point: the item carries the favorite's id, since the list can
    /// change between the menu being built and the item being chosen.
    @objc func goToFavoriteMenuItem(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID,
              let favorite = FavoritesStore.shared.favorite(withID: id) else {
            NSSound.beep()
            return
        }
        goToFavorite(favorite)
    }

    /// Jump to a saved place, reconnecting first when it belongs to another account.
    func goToFavorite(_ favorite: Favorite) {
        // Compares the whole account, provider included — two clouds can each have an
        // account called "prod", and jumping to the wrong one would be worse than
        // reconnecting unnecessarily.
        guard favorite.account == account, provider != nil else {
            pendingRestoreLocation = favorite.location
            connect(account: favorite.account)
            return
        }
        // Deliberately not calling `sidebar.select`: the favorite row stays selected,
        // the way Finder leaves a sidebar favorite highlighted rather than bouncing
        // the selection down to the volume it lives on.
        currentContainerName = favorite.container
        content.location = favorite.location
    }

    @objc func navigateToEnclosingFolder(_ sender: Any?) {
        content.navigateUp()
    }

    @objc func openSelection(_ sender: Any?) {
        content.openSelection()
    }

    @objc func sortBy(_ sender: Any?) {
        guard let key = (sender as? NSMenuItem)?.representedObject as? SortKey else { return }
        content.setSort(key)
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

    func connect(account: ProviderAccount) {
        // The one gate every ingress funnels through — typed, favorited, dragged, or
        // restored. An Azure account name lands in host position of every request
        // URL, so a malformed one must never reach the endpoint (see
        // `AzureStorageEndpoint.isValidAccountName`).
        if account.kind == .azureBlob, !AzureStorageEndpoint.isValidAccountName(account.name) {
            content.showMessage("“\(account.name)” isn’t a valid storage account name.\n\nAccount names are 3–24 lowercase letters and numbers.")
            return
        }
        let provider = ProviderFactory.make(for: account)
        self.provider = provider
        content.provider = provider
        content.location = nil
        sidebar.setContainers([])
        content.showMessage("Loading \(account.kind.containerNoun)s from \(account.name)…")
        self.account = account
        sidebar.currentAccount = account
        updateWindowTitle(for: nil)
        // Locations from a previous account are meaningless in this one.
        history.reset()
        StrataDefaults.lastAccount = account

        Task { @MainActor in
            do {
                let containers = try await provider.listContainers()
                self.sidebar.setContainers(containers)
                // Prefer the container the user was last in; the saved container may
                // no longer exist, in which case fall back to the first.
                let restoreTarget = self.pendingRestoreLocation.flatMap { location in
                    containers.first { $0.name == location.container }
                }
                if let restoreTarget {
                    self.sidebar.select(restoreTarget)
                } else if let first = containers.first {
                    self.pendingRestoreLocation = nil
                    self.sidebar.select(first)
                } else {
                    self.content.showMessage("No \(account.kind.containerNoun)s in “\(account.name).”")
                }
            } catch {
                let message = StorageErrorText.message(for: error, kind: account.kind)
                self.content.showMessage("Couldn\u{2019}t connect to \u{201C}\(account.name)\u{201D}.\n\n\(message.full)")
            }
        }
    }
}

// MARK: - QLPreviewPanelController

/// The shared Quick Look panel finds its controller by walking the responder chain,
/// which is why these live on the split view controller rather than on
/// `QuickLookController` — the panel would never find that object.
extension BrowserSplitViewController {

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    // Quick Look calls these on the main thread, but they're declared nonisolated,
    // and Swift 6 warns (and a later language mode will refuse) about touching the
    // panel's main-actor properties from them without saying so.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = quickLook
            panel.delegate = quickLook
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}
