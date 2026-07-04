import AppKit
import UniformTypeIdentifiers

/// Hosts the container sidebar, object list, and inspector, and coordinates between
/// them. Owns the connected provider and the Connect / Refresh / Upload / Inspector
/// actions (reached from the menu bar and toolbar via the responder chain).
@MainActor
final class BrowserSplitViewController: NSSplitViewController {

    let sidebar = ContainerSidebarViewController()
    let objectList = ObjectListViewController()
    let inspector = InspectorViewController()

    private var provider: (any StorageProvider)?
    private var currentContainerName: String?

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(viewController: objectList)
        contentItem.minimumThickness = 400
        addSplitViewItem(contentItem)

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 380
        inspectorItem.canCollapse = true
        addSplitViewItem(inspectorItem)

        sidebar.onSelectContainer = { [weak self] container in
            guard let self, let provider = self.provider else { return }
            self.currentContainerName = container.name
            self.objectList.provider = provider
            self.objectList.location = BrowserLocation(container: container.name, prefix: "")
        }

        objectList.onSelectionChange = { [weak self] object in
            guard let self else { return }
            self.inspector.present(object: object, provider: self.provider, containerName: self.currentContainerName)
        }
    }

    // MARK: - Actions

    @objc func connectAzureStorageAccount(_ sender: Any?) {
        guard let window = view.window else { return }

        let alert = NSAlert()
        alert.messageText = "Connect to Azure Storage Account"
        alert.informativeText = "Uses your current Azure CLI (az) login. Enter the storage account name."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "storage account name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let account = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !account.isEmpty else { return }
            self?.connect(account: account)
        }
    }

    @objc func refreshListing(_ sender: Any?) {
        objectList.reload()
    }

    @objc func toggleObjectInspector(_ sender: Any?) {
        guard let item = splitViewItems.last, item.behavior == .inspector else { return }
        item.animator().isCollapsed.toggle()
    }

    @objc func uploadFiles(_ sender: Any?) {
        guard let window = view.window, provider != nil, let location = objectList.location else {
            NSSound.beep()
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        let destination = location.prefix.isEmpty ? location.container : "\(location.container)/\(location.prefix)"
        panel.message = "Choose files to upload to \(destination)"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            self?.confirmUpload(urls: panel.urls, to: location)
        }
    }

    // Enable the actions only when they make sense.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(refreshListing(_:)):
            return provider != nil
        case #selector(uploadFiles(_:)):
            return provider != nil && objectList.location != nil
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

    private struct PlannedUpload {
        let url: URL
        let key: String
        let plan: UploadPlan
        let contentType: String?
    }

    private func confirmUpload(urls: [URL], to location: BrowserLocation) {
        guard let window = view.window else { return }

        let planned: [PlannedUpload] = urls.map { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            return PlannedUpload(
                url: url,
                key: location.prefix + url.lastPathComponent,
                plan: UploadPlan(byteCount: size, endpoint: .blob),
                contentType: contentType
            )
        }

        // The differentiator, surfaced at the moment of action: show exactly which
        // event each upload will emit before the user commits.
        let alert = NSAlert()
        alert.messageText = urls.count == 1 ? "Upload “\(urls[0].lastPathComponent)”?" : "Upload \(urls.count) files?"
        let destination = location.prefix.isEmpty ? "\(location.container) (root)" : "\(location.container)/\(location.prefix)"
        let lines = planned.map { "• \(lastComponent($0.key)) — \($0.plan.predictedEventSummary)" }
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

        Task { @MainActor in
            do {
                for item in planned {
                    let data = try Data(contentsOf: item.url)
                    var plan = item.plan
                    plan.byteCount = Int64(data.count)
                    try await provider.upload(data, toKey: item.key, in: container, contentType: item.contentType, plan: plan)
                }
                if let last = planned.last {
                    self.objectList.reloadSelecting(key: last.key)
                } else {
                    self.objectList.reload()
                }
            } catch {
                self.presentUploadError(error)
            }
        }
    }

    private func presentUploadError(_ error: Error) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if case StorageProviderError.dataPlaneForbidden(let account) = error {
            alert.messageText = "Upload not permitted"
            alert.informativeText = "This identity can’t write to “\(account).” Writing blobs needs a Storage Blob Data Contributor (or Owner) role — read/list roles aren’t enough."
        } else {
            alert.messageText = "Upload failed"
            alert.informativeText = error.localizedDescription
        }
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
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
        objectList.provider = provider
        objectList.location = nil
        sidebar.setContainers([])
        objectList.showMessage("Loading containers from \(account)…")
        view.window?.title = account
        view.window?.subtitle = "Azure Blob Storage"

        Task { @MainActor in
            do {
                let containers = try await provider.listContainers()
                self.sidebar.setContainers(containers)
                if let first = containers.first {
                    self.sidebar.select(first)
                } else {
                    self.objectList.showMessage("No containers in “\(account).”")
                }
            } catch StorageProviderError.dataPlaneForbidden(let account) {
                self.objectList.showMessage("Authenticated, but this identity lacks a “Storage Blob Data” role on “\(account).”\n\nManagement roles (Owner/Contributor/Reader) don’t grant data-plane access.")
            } catch StorageProviderError.unauthorized {
                self.objectList.showMessage("Not authorized. Check that `az login` has a session for the account’s tenant.")
            } catch {
                self.objectList.showMessage("Couldn’t connect to “\(account).”\n\n\(error.localizedDescription)")
            }
        }
    }
}
