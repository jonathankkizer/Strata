import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var browserWindowControllers: [BrowserWindowController] = []
    private var preferencesWindowController: PreferencesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(target: self)
        openBrowserWindow(sender: nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows && browserWindowControllers.isEmpty {
            openBrowserWindow(sender: nil)
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

    // MARK: - Private

    private func openBrowserWindow(sender: Any?, asTab: Bool = false) {
        // The first open window owns the saved frame; the rest cascade off it.
        let controller = BrowserWindowController(isPrimary: browserWindowControllers.isEmpty)
        browserWindowControllers.append(controller)
        controller.onWindowClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.browserWindowControllers.removeAll { $0 === controller }
        }
        if asTab, let keyWindow = NSApp.keyWindow, let newWindow = controller.window {
            keyWindow.addTabbedWindow(newWindow, ordered: .above)
            newWindow.makeKeyAndOrderFront(sender)
        } else {
            controller.showWindow(sender)
        }
    }
}
