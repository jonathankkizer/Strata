import Testing
import AppKit
@testable import Strata

/// The browser window is `.fullSizeContentView` under a translucent unified toolbar, so
/// every pane extends behind the titlebar and whatever it paints there is what the
/// toolbar tints against. Panes that disagree produce a visible seam in the titlebar.
///
/// The sidebar is the deliberate exception — it stays transparent so its vibrancy shows
/// through, which is the standard Mac look and lines up with the toolbar's sidebar
/// tracking separator.
@Suite("Titlebar backdrop consistency")
@MainActor
struct TitlebarBackdropTests {

    @Test("The inspector paints the same backdrop as the browse panes")
    func inspectorMatchesContentBackdrop() throws {
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()

        let scrollView = try #require(inspector.view as? NSScrollView)
        // Painting nothing is what caused the seam: the toolbar picked up the window
        // backdrop over the inspector and the control background over the content.
        #expect(scrollView.drawsBackground)
        #expect(scrollView.backgroundColor == .controlBackgroundColor)
    }

    /// `NSScrollView` already defaults to an opaque control background, which is why the
    /// list and columns panes match without saying so explicitly — and why the inspector
    /// having opted out was the odd one.
    @Test("An untouched scroll view already agrees with that backdrop")
    func defaultScrollViewAgrees() {
        let plain = NSScrollView()
        #expect(plain.drawsBackground)
        #expect(plain.backgroundColor == .controlBackgroundColor)
    }

    /// The sidebar must *not* be given a backdrop — doing so would flatten the vibrancy
    /// that makes it read as a sidebar at all.
    @Test("The sidebar stays transparent on purpose")
    func sidebarStaysTransparent() throws {
        let sidebar = ContainerSidebarViewController()
        sidebar.loadViewIfNeeded()

        let scrollView = try #require(sidebar.view as? NSScrollView)
        #expect(scrollView.drawsBackground == false)
    }
}
