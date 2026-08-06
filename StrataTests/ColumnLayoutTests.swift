import Testing
import AppKit
@testable import Strata

@Suite("Column widths")
struct ColumnLayoutTests {

    @Test("A width inside the allowed range is left alone")
    func clampPassesThrough() {
        #expect(ColumnLayout.clamp(300) == 300)
        #expect(ColumnLayout.clamp(ColumnLayout.defaultWidth) == ColumnLayout.defaultWidth)
    }

    @Test("A column can't be dragged narrower than a name can live in, or wider than a pane")
    func clampBounds() {
        #expect(ColumnLayout.clamp(10) == ColumnLayout.minimumWidth)
        #expect(ColumnLayout.clamp(-500) == ColumnLayout.minimumWidth)
        #expect(ColumnLayout.clamp(99_999) == ColumnLayout.maximumWidth)
    }

    @Test("Sizing to fit leaves room for the icon and the disclosure chevron")
    func widthToFitAddsRowChrome() {
        // A name needing 200pt of text can't live in a 200pt column: the icon, the
        // chevron, and the gaps around them come out of the same width.
        #expect(ColumnLayout.widthToFit(longestNameWidth: 200) == 200 + ColumnLayout.rowChrome)
    }

    @Test("An empty column still sizes to something usable")
    func widthToFitEmptyColumn() {
        #expect(ColumnLayout.widthToFit(longestNameWidth: 0) == ColumnLayout.minimumWidth)
    }

    @Test("A very long name sizes to fit up to the maximum, not past it")
    func widthToFitClampsLongNames() {
        #expect(ColumnLayout.widthToFit(longestNameWidth: 5_000) == ColumnLayout.maximumWidth)
    }

    /// `UserDefaults.double` reads a missing key back as 0, which must not be mistaken
    /// for a column the user dragged shut.
    @Test("An unset or nonsense stored width falls back to the default")
    func restoredRejectsJunk() {
        #expect(ColumnLayout.restored(0) == ColumnLayout.defaultWidth)
        #expect(ColumnLayout.restored(-1) == ColumnLayout.defaultWidth)
        #expect(ColumnLayout.restored(.nan) == ColumnLayout.defaultWidth)
        #expect(ColumnLayout.restored(.infinity) == ColumnLayout.defaultWidth)
    }

    @Test("A stored width from another build is brought back into range")
    func restoredClamps() {
        #expect(ColumnLayout.restored(5_000) == ColumnLayout.maximumWidth)
        #expect(ColumnLayout.restored(320) == 320)
    }

    /// `rowChrome` is a copy of `ColumnNameCellView`'s constraint constants, and a cell
    /// whose layout drifts away from it would size-to-fit to a truncating width.
    @Test("Row chrome accounts for the icon, both gaps, and the chevron's scroller clearance")
    func rowChromeMatchesTheCell() {
        let leadingInset: CGFloat = 4
        let icon: CGFloat = 16
        let iconToLabel: CGFloat = 6
        let labelToChevron: CGFloat = 4
        let chevron: CGFloat = 11
        let scrollerClearance: CGFloat = 16
        #expect(
            ColumnLayout.rowChrome
                == leadingInset + icon + iconToLabel + labelToChevron + chevron + scrollerClearance
        )
    }
}

@Suite("Scroll axis latching")
struct ScrollAxisLatchTests {

    /// `#expect` evaluates its expression inside a closure that captures immutably, so a
    /// `mutating` call has to be made outside the macro and its result handed in.
    private func route(_ latch: inout ScrollAxisLatch, _ steps: ScrollAxisLatch.Step...) -> [Bool] {
        steps.map { latch.route($0) }
    }

    @Test("A sideways swipe goes to the strip of columns")
    func horizontalGestureRoutesOut() {
        var latch = ScrollAxisLatch()
        #expect(route(&latch, .begins(deltaX: -30, deltaY: 2)) == [true])
    }

    @Test("A downward swipe stays in the column")
    func verticalGestureStaysPut() {
        var latch = ScrollAxisLatch()
        #expect(route(&latch, .begins(deltaX: 1, deltaY: 40)) == [false])
    }

    /// The bug this exists to prevent: a sideways swipe that drifts vertically must not
    /// hand itself back to the column halfway through.
    @Test("The axis is decided once and held for the rest of the gesture")
    func gestureHoldsItsAxis() {
        var latch = ScrollAxisLatch()
        let routed = route(&latch, .begins(deltaX: -20, deltaY: 3), .continues, .continues, .ends)
        #expect(routed == [true, true, true, true])
    }

    @Test("A vertical gesture stays in the column even as it drifts sideways")
    func verticalGestureHoldsToo() {
        var latch = ScrollAxisLatch()
        let routed = route(&latch, .begins(deltaX: 0, deltaY: 25), .continues, .ends)
        #expect(routed == [false, false, false])
    }

    /// A gesture that ended must not leave the latch armed for whatever comes next.
    @Test("The next gesture is free to go the other way")
    func latchResetsBetweenGestures() {
        var latch = ScrollAxisLatch()
        let routed = route(
            &latch,
            .begins(deltaX: -30, deltaY: 0), .ends,
            .begins(deltaX: 0, deltaY: 30), .ends
        )
        #expect(routed == [true, true, false, false])
    }

    /// Momentum arrives after the fingers lift, and belongs to the gesture that threw it —
    /// so it is classified as a continuation and rides the latch that gesture set.
    @Test("Momentum after the swipe keeps going the same way")
    func momentumFollowsTheGesture() {
        var latch = ScrollAxisLatch()
        let routed = route(&latch, .begins(deltaX: -40, deltaY: 1), .continues, .continues)
        #expect(routed == [true, true, true])
    }

    @Test("A wheel notch decides on its own, with no gesture around it")
    func standaloneWheelDecidesPerEvent() {
        var latch = ScrollAxisLatch()
        // A plain notch, then shift-wheel — which the system reports horizontally.
        let routed = route(&latch, .standalone(deltaX: 0, deltaY: -3), .standalone(deltaX: -3, deltaY: 0))
        #expect(routed == [false, true])
    }

    @Test("An ambiguous gesture stays with the rows")
    func tieStaysInTheColumn() {
        var latch = ScrollAxisLatch()
        let routed = route(&latch, .begins(deltaX: 5, deltaY: 5), .ends, .begins(deltaX: 0, deltaY: 0))
        #expect(routed == [false, false, false])
    }
}

/// A provider that answers instantly with nothing, so the columns view can be built and
/// measured without a network or an account.
private struct StubProvider: StorageProvider {
    var kind: ProviderKind = .azureBlob
    var displayName = "stub"

    func listContainers() async throws -> [StorageContainer] { [] }
    func listObjects(in container: StorageContainer, prefix: String) async throws -> [StorageObject] { [] }
    func fetchMetadata(for object: StorageObject, in container: StorageContainer) async throws -> ObjectMetadata {
        throw StorageProviderError.notImplemented
    }
    func objectURL(forKey key: String, in container: StorageContainer) -> URL? { nil }
    func upload(from fileURL: URL, toKey key: String, in container: StorageContainer, contentType: String?, plan: UploadPlan, onProgress: (@Sendable (Int64, Int64) -> Void)?) async throws {
        throw StorageProviderError.notImplemented
    }
    func download(fromKey key: String, in container: StorageContainer, to destinationURL: URL, onProgress: (@Sendable (Int64, Int64) -> Void)?) async throws {
        throw StorageProviderError.notImplemented
    }
}

/// The width lives in a preference so a column the user has widened stays widened —
/// through the next folder, and the next launch.
@Suite("Columns open at the remembered width", .serialized)
@MainActor
struct ColumnWidthPersistenceTests {

    private func withStoredWidth(_ width: CGFloat, _ body: () throws -> Void) rethrows {
        let original = StrataDefaults.columnWidth
        defer { StrataDefaults.columnWidth = original }
        StrataDefaults.columnWidth = width
        try body()
    }

    @Test("A column is built at the persisted width, plus its separator")
    func columnUsesStoredWidth() throws {
        try withStoredWidth(340) {
            let columns = ColumnBrowserViewController()
            columns.provider = StubProvider()
            columns.loadViewIfNeeded()
            columns.view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)

            columns.show(BrowserLocation(container: "bucket", prefix: ""))
            columns.view.layoutSubtreeIfNeeded()

            let column = try #require(firstColumnView(in: columns.view))
            #expect(column.frame.width == 340 + ColumnLayout.separatorWidth)
        }
    }

    /// The grab area is added last so it hit-tests ahead of the table underneath it —
    /// otherwise the pointer lands on a row and the divider can never be dragged.
    @Test("The trailing edge of a column is grabbable")
    func trailingEdgeHitsTheDivider() throws {
        try withStoredWidth(ColumnLayout.defaultWidth) {
            let columns = ColumnBrowserViewController()
            columns.provider = StubProvider()
            columns.loadViewIfNeeded()
            columns.view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)

            columns.show(BrowserLocation(container: "bucket", prefix: ""))
            columns.view.layoutSubtreeIfNeeded()

            let column = try #require(firstColumnView(in: columns.view))
            // `hitTest` takes a point in the receiver's *superview* coordinates, and the
            // first column starts at the stack's origin.
            let onTheEdge = NSPoint(x: column.frame.maxX - 2, y: column.frame.midY)
            let hit = try #require(column.hitTest(onTheEdge))
            #expect(hit.frame.width < 10)
            #expect((hit as? NSScrollView) == nil)

            // A point well inside the column belongs to the rows, not the divider.
            let inTheRows = NSPoint(x: column.frame.midX, y: column.frame.midY)
            let inside = try #require(column.hitTest(inTheRows))
            #expect(inside !== hit)
        }
    }

    /// A width from a build with different bounds — or a corrupted one — must not be
    /// able to open a column too narrow to use.
    @Test("An out-of-range stored width is brought back into range")
    func storedWidthIsClamped() throws {
        try withStoredWidth(5_000) {
            #expect(StrataDefaults.columnWidth == ColumnLayout.maximumWidth)
        }
    }

    private func firstColumnView(in root: NSView) -> NSView? {
        guard let scrollView = root.subviews.compactMap({ $0 as? NSScrollView }).first,
              let stack = scrollView.documentView as? NSStackView else { return nil }
        return stack.arrangedSubviews.first
    }
}

/// A scroller that can never move is a stripe down the edge of the app. Both of these
/// panes hold a short list that usually fits, so the bar has to earn its place.
@Suite("Scrollers appear only when there is something to scroll")
@MainActor
struct ScrollerVisibilityTests {

    @Test("The sidebar hides its scroller when the places fit")
    func sidebarAutohides() throws {
        let sidebar = ContainerSidebarViewController()
        sidebar.loadViewIfNeeded()

        let backdrop = try #require(sidebar.view as? NSVisualEffectView)
        let scrollView = try #require(backdrop.subviews.compactMap { $0 as? NSScrollView }.first)
        #expect(scrollView.autohidesScrollers)
    }

    @Test("The inspector hides its scroller when the properties fit")
    func inspectorAutohides() throws {
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()

        let scrollView = try #require(inspector.view as? NSScrollView)
        #expect(scrollView.autohidesScrollers)
    }
}
