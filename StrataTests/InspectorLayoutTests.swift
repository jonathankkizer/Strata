import Testing
import AppKit
@testable import Strata

/// The inspector follows the Finder's preview pane: rows span the pane with the label
/// flush left and the value flush right.
@Suite("Inspector layout", .serialized)
@MainActor
struct InspectorLayoutTests {

    private let width: CGFloat = 300

    private func shown(_ objects: [StorageObject], showsMore: Bool = false) -> InspectorViewController {
        let saved = StrataDefaults.inspectorShowsMore
        StrataDefaults.inspectorShowsMore = showsMore
        defer { StrataDefaults.inspectorShowsMore = saved }
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()
        inspector.view.frame = NSRect(x: 0, y: 0, width: width, height: 800)
        inspector.present(objects: objects, provider: nil, containerName: nil)
        inspector.view.layoutSubtreeIfNeeded()
        return inspector
    }

    private func field(_ text: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.stringValue == text { return field }
        for subview in view.subviews {
            if let found = field(text, in: subview) { return found }
        }
        return nil
    }

    private func button(_ title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for subview in view.subviews {
            if let found = button(title, in: subview) { return found }
        }
        return nil
    }

    private let blob = StorageObject(
        key: "census/2025_1/admissions.csv", size: 7_024, lastModified: Date(),
        storageClass: "Hot", contentType: "application/octet-stream", etag: "\"0x8DF\""
    )

    /// A vertical NSStackView has no fill alignment; relying on one left every row at
    /// its content's width, lined up against the right edge.
    @Test("Labels sit on the left edge and values on the right")
    func rowsSpanThePane() throws {
        let inspector = shown([blob])
        let label = try #require(field("Tier", in: inspector.view))
        let value = try #require(field("Hot", in: inspector.view))
        let labelFrame = label.convert(label.bounds, to: inspector.view)
        let valueFrame = value.convert(value.bounds, to: inspector.view)
        #expect(abs(labelFrame.minX - 12) < 3)
        #expect(abs(valueFrame.maxX - (width - 12)) < 3)
    }

    @Test("The name is flush left under the icon, as in the Finder")
    func nameIsLeading() throws {
        let inspector = shown([blob])
        let name = try #require(field("admissions.csv", in: inspector.view))
        #expect(abs(name.convert(name.bounds, to: inspector.view).minX - 12) < 3)
        // The kind comes from the extension: octet-stream says nothing.
        #expect(field("comma-separated values – 7 KB", in: inspector.view) != nil)
    }

    @Test("Show More adds the details and nothing else changes")
    func showMore() {
        let brief = shown([blob])
        #expect(field("ETag", in: brief.view) == nil)
        #expect(button("Show More", in: brief.view) != nil)
        let full = shown([blob], showsMore: true)
        #expect(field("ETag", in: full.view) != nil)
        #expect(field("7,024 bytes", in: full.view) != nil)
        #expect(field("Tier", in: full.view) != nil)
        #expect(button("Show Less", in: full.view) != nil)
    }

    @Test("The exact size reads like the Finder's")
    func exactSize() {
        #expect(InspectorViewController.exactSize(1) == "1 byte")
        #expect(InspectorViewController.exactSize(7_024) == "7,024 bytes")
    }
}
