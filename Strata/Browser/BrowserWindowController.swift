import AppKit

/// The main browser window. Programmatic NSWindow with autosaved frame (state
/// restoration), native tabbing, and a toolbar. Dual-pane content lives in the
/// content view controller.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Strata"
        window.isRestorable = true
        window.setFrameAutosaveName("StrataBrowserWindow")
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "StrataBrowser"
        window.minSize = NSSize(width: 720, height: 480)

        self.init(window: window)

        window.delegate = self
        window.contentViewController = BrowserViewController()
        configureToolbar(for: window)
        window.center()
    }

    private func configureToolbar(for window: NSWindow) {
        let toolbar = NSToolbar(identifier: "StrataBrowserToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }
}
