import AppKit

/// The Transfers window — Window ▸ Transfers (⌥⌘L, Safari's shortcut for its
/// Downloads list). The same list as the toolbar popover, but it stays open, can be
/// resized, and doesn't depend on a browser window's toolbar being visible or the
/// Transfers item being in it.
@MainActor
final class TransfersWindowController: NSWindowController, NSWindowDelegate {

    static let shared = TransfersWindowController()

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = "Transfers"
        window.minSize = NSSize(width: 340, height: 200)
        // A utility list, not a document: it shouldn't join the browser's tabs.
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentViewController = TransfersViewController(mode: .window)
        self.init(window: window)
        window.delegate = self
        if !window.setFrameUsingName("StrataTransfersWindow") {
            window.center()
        }
        window.setFrameAutosaveName("StrataTransfersWindow")
    }

    func toggle(_ sender: Any?) {
        if window?.isKeyWindow == true {
            close()
        } else {
            show(sender)
        }
    }

    func show(_ sender: Any?) {
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
}
