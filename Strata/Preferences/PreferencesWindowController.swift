import AppKit

/// Classic Mac preferences window: an NSToolbar of icon+label items, one per
/// pane, with the window animating its size between panes. Explicitly NOT the
/// SwiftUI Settings scene. Stubbed here with a single placeholder pane; the
/// toolbar-driven multi-pane behavior lands next.
@MainActor
final class PreferencesWindowController: NSWindowController {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isRestorable = true
        window.setFrameAutosaveName("StrataPreferencesWindow")
        self.init(window: window)

        let label = NSTextField(labelWithString: "Preferences — upload strategy, credentials, and event-awareness panes go here.")
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
        ])
        window.contentView = content
        window.center()
    }
}
