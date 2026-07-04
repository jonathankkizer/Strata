import AppKit

/// Hosts the container sidebar + object list and coordinates between them. Owns the
/// connected provider and the Connect / Refresh actions (reached from the menu bar
/// and toolbar via the responder chain).
@MainActor
final class BrowserSplitViewController: NSSplitViewController {

    let sidebar = ContainerSidebarViewController()
    let objectList = ObjectListViewController()

    private var provider: (any StorageProvider)?

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(viewController: objectList)
        contentItem.minimumThickness = 420
        addSplitViewItem(contentItem)

        sidebar.onSelectContainer = { [weak self] container in
            guard let self, let provider = self.provider else { return }
            self.objectList.provider = provider
            self.objectList.location = BrowserLocation(container: container.name, prefix: "")
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

    // Enable the actions only when they make sense.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(refreshListing(_:)):
            return provider != nil
        case #selector(connectAzureStorageAccount(_:)):
            return true
        default:
            return true
        }
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
