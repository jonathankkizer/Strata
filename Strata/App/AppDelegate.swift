import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    private var browserWindowControllers: [BrowserWindowController] = []
    private var preferencesWindowController: PreferencesWindowController?
    private var welcomeWindowController: WelcomeWindowController?
    /// Held for the app's lifetime — NSMenu's delegate reference is weak.
    private let favoritesMenuController = FavoritesMenuController()
    let updateCoordinator = UpdateCoordinator()
    private let transferActivity = TransferActivityMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(target: self, favoritesMenuDelegate: favoritesMenuController)
        openInitialWindow()
        NSApp.activate()
        updateCoordinator.start()
        transferActivity.start()
        UNUserNotificationCenter.current().delegate = self
        Task.detached(priority: .background) { PreviewCache.prune() }
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
        if queue.hasActive {
            let count = queue.activeCount
            let alert = NSAlert()
            alert.messageText = "Quit Strata?"
            let noun = count == 1 ? "transfer" : "transfers"
            alert.informativeText = "\(count) \(noun) in progress will be cancelled."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        guard queue.hasUnfinishedUploads else { return .terminateNow }
        // Unfinished uploads may be holding S3 multipart uploads open; give aborting
        // them a few seconds rather than leaving their parts to be billed.
        Task { @MainActor in
            await queue.shutDown(timeout: .seconds(5))
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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

    /// The tab bar's + button sends this up the responder chain; without it the
    /// button isn't shown.
    @objc func newWindowForTab(_ sender: Any?) {
        newBrowserTab(sender)
    }

    /// Window ▸ Transfers: shows the window, or closes it if it's already in front.
    @objc func showTransfers(_ sender: Any?) {
        TransfersWindowController.shared.toggle(sender)
    }

    // MARK: - Notifications

    /// Clicking a "transfers finished" notification opens the list it's about.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            NSApp.activate()
            TransfersWindowController.shared.show(nil)
        }
    }

    @objc func showStrataHelp(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/jonathankkizer/Strata#readme")!)
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
            browser.browser.connectStorageAccount(nil)
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
