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

    /// The sidebar gets the opposite treatment: a real `.sidebar` material, with the
    /// scroll view transparent on top of it.
    ///
    /// `.sourceList` styling paints no background of its own — it expects to sit on that
    /// material. Without it the sidebar was bare window background, which is what made
    /// the titlebar above it read as undifferentiated.
    @Test("The sidebar sits on a sidebar material")
    func sidebarHasSidebarMaterial() throws {
        let sidebar = ContainerSidebarViewController()
        sidebar.loadViewIfNeeded()

        let backdrop = try #require(sidebar.view as? NSVisualEffectView)
        #expect(backdrop.material == .sidebar)
        // Behind-window blending is what makes a sidebar translucent over the desktop;
        // `.withinWindow` would look flat and opaque.
        #expect(backdrop.blendingMode == .behindWindow)
        // Dims when the window isn't frontmost, like every other Mac sidebar.
        #expect(backdrop.state == .followsWindowActiveState)

        // The scroll view on top must stay transparent, or it would paint over the
        // material it's sitting on.
        let scrollView = try #require(
            backdrop.subviews.compactMap { $0 as? NSScrollView }.first
        )
        #expect(scrollView.drawsBackground == false)
    }
}
