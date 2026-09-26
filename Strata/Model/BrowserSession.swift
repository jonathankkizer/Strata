import Foundation

/// The browser windows and tabs open when Strata last ran, so the next launch can
/// put them back: each tab's account, folder and view, which tab was in front, and
/// where each window was.
///
/// Strata keeps this itself rather than leaning on AppKit's state restoration,
/// because with the system's default setting ("Close windows when quitting an
/// application") AppKit restores nothing after an ordinary Quit — and reopening
/// where you were is what the "Reopen windows" preference promises.
struct BrowserSession: Codable, Equatable, Sendable {

    struct Tab: Codable, Equatable, Sendable {
        var account: ProviderAccount
        var container: String?
        var prefix: String
        /// `BrowseMode` raw value: list or columns.
        var mode: Int

        var location: BrowserLocation? {
            container.map { BrowserLocation(container: $0, prefix: prefix) }
        }
    }

    struct Window: Codable, Equatable, Sendable {
        var tabs: [Tab]
        /// Which tab was in front.
        var selectedTab: Int
        /// `NSWindow.frameDescriptor`.
        var frame: String?
    }

    /// Front to back.
    var windows: [Window]

    var isEmpty: Bool { windows.isEmpty }

    /// Drops windows with no tabs worth restoring and clamps each selected index,
    /// so a damaged or hand-edited entry can't crash a launch.
    func sanitized() -> BrowserSession {
        BrowserSession(windows: windows.compactMap { window in
            guard !window.tabs.isEmpty else { return nil }
            var window = window
            window.selectedTab = min(max(window.selectedTab, 0), window.tabs.count - 1)
            return window
        })
    }
}
