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

    /// The split view's divider draws nothing on macOS 26, so the inspector draws its
    /// own edge: a separator on its leading side, starting below the toolbar.
    @Test("The inspector has a visible edge against the browse pane")
    func inspectorHasSeparator() throws {
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()
        let separator = try #require(inspector.separator)
        #expect(separator.boxType == .separator)
        #expect(separator.superview === inspector.view)
    }

    /// The separator is an `NSBox`, which starts out thinking it is horizontal and
    /// hugs a 1pt height at a priority above a window drag's. Unchecked, it held the
    /// whole window at toolbar height.
    @Test("The inspector's edge doesn't stop the window growing taller")
    func inspectorSeparatorDoesNotFixHeight() throws {
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        inspector.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(inspector.view)
        let drag = inspector.view.heightAnchor.constraint(equalToConstant: 600)
        drag.priority = .dragThatCanResizeWindow
        NSLayoutConstraint.activate([
            inspector.view.topAnchor.constraint(equalTo: host.topAnchor),
            inspector.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            inspector.view.widthAnchor.constraint(equalToConstant: 260),
            drag,
        ])
        host.layoutSubtreeIfNeeded()
        #expect(inspector.view.frame.height == 600)
        let separator = try #require(inspector.separator)
        #expect(separator.frame.height > 500)
    }

    @Test("The inspector paints the same backdrop as the browse panes")
    func inspectorMatchesContentBackdrop() throws {
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()

        let scrollView = try #require(inspector.view.subviews.compactMap { $0 as? NSScrollView }.first)
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
