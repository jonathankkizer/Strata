import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var browserWindowControllers: [BrowserWindowController] = []
    private var preferencesWindowController: PreferencesWindowController?
    private var welcomeWindowController: WelcomeWindowController?
    /// Held for the app's lifetime — NSMenu's delegate reference is weak.
    private let favoritesMenuController = FavoritesMenuController()
    let updateCoordinator = UpdateCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(target: self, favoritesMenuDelegate: favoritesMenuController)
        openInitialWindow()
        NSApp.activate()
        updateCoordinator.start()
    }

    private func openInitialWindow() {
        switch LaunchPlan.decide(
            reconnectOnLaunch: StrataDefaults.reconnectOnLaunch,
            lastAccount: StrataDefaults.lastAccount,
            showWelcomeOnLaunch: StrataDefaults.showWelcomeOnLaunch
        ) {
        case .welcome:
            showWelcomeWindow(nil)
        case .reconnectingBrowser, .emptyBrowser:
            // Same call either way: the browse surface reconnects on appearance when
            // the preference says to, so nothing extra is needed here.
            openBrowserWindow(sender: nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows && browserWindowControllers.isEmpty {
            openInitialWindow()
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let queue = TransferQueue.shared
        guard queue.hasActive else { return .terminateNow }

        let count = queue.activeCount
        let alert = NSAlert()
        alert.messageText = "Quit Strata?"
        let noun = count == 1 ? "transfer" : "transfers"
        alert.informativeText = "\(count) \(noun) in progress will be cancelled."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: - Actions wired from the main menu

    @objc func showPreferences(_ sender: Any?) {
        let controller = preferencesWindowController ?? PreferencesWindowController()
        preferencesWindowController = controller
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
    }

    @objc func newBrowserWindow(_ sender: Any?) {
        openBrowserWindow(sender: sender)
    }

    @objc func newBrowserTab(_ sender: Any?) {
        openBrowserWindow(sender: sender, asTab: true)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updateCoordinator.checkManually()
    }

    @objc func showWelcomeWindow(_ sender: Any?) {
        let controller = welcomeWindowController ?? makeWelcomeWindowController()
        welcomeWindowController = controller
        controller.syncShowOnLaunchCheckbox()
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
    }

    // MARK: - Private

    private func makeWelcomeWindowController() -> WelcomeWindowController {
        let controller = WelcomeWindowController()
        controller.onConnect = { [weak self] in
            guard let self else { return }
            // Straight into the picker in the new window — clicking "Connect…" already
            // said what the user wants; making them find the command again wouldn't.
            let browser = self.openBrowserWindow(sender: nil)
            browser.browser.connectAzureStorageAccount(nil)
        }
        controller.onReconnect = { [weak self] account in
            self?.openBrowserWindow(sender: nil).browser.connect(account: account)
        }
        controller.onOpenFavorite = { [weak self] favorite in
            self?.openBrowserWindow(sender: nil).browser.goToFavorite(favorite)
        }
        return controller
    }

    @discardableResult
    private func openBrowserWindow(sender: Any?, asTab: Bool = false) -> BrowserWindowController {
        // The first open window owns the saved frame; the rest cascade off it.
        let controller = BrowserWindowController(isPrimary: browserWindowControllers.isEmpty)
        browserWindowControllers.append(controller)
        controller.onWindowClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.browserWindowControllers.removeAll { $0 === controller }
        }
        // The Welcome window is not a tabbing peer; tabbing onto it would be nonsense.
        if asTab, let keyWindow = NSApp.keyWindow,
           keyWindow.contentViewController is BrowserSplitViewController,
           let newWindow = controller.window {
            keyWindow.addTabbedWindow(newWindow, ordered: .above)
            newWindow.makeKeyAndOrderFront(sender)
        } else {
            controller.showWindow(sender)
        }
        return controller
    }
}
