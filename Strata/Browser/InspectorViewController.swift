import AppKit
import UniformTypeIdentifiers

/// A flipped container so scroll content stays pinned to the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Finder "Get Info"–styled inspector for the selected object. Shows listing-derived
/// properties immediately, enriches with a HEAD (Get Blob Properties) when possible,
/// and includes the differentiating "Event Grid" section predicting which event a
/// re-upload of this blob would emit.
@MainActor
final class InspectorViewController: NSViewController {

    /// A label/value pair, plus whether the value is prose (wraps onto more lines)
    /// or a single unbreakable token (truncates in the middle).
    private struct Row {
        let label: String
        let value: String
        let wraps: Bool

        init(_ label: String, _ value: String, wraps: Bool = true) {
            self.label = label
            self.value = value
            self.wraps = wraps
        }
    }

    /// The pane's side margins, and what everything in it lines up on.
    private static let inset: CGFloat = 12
    /// Above and below a row's text, so rows sit on a comfortable pitch with the
    /// hairline between them.
    private static let rowPadding: CGFloat = 5
    private static let sectionSpacing: CGFloat = 20
    /// The Finder's size for a file icon in its preview pane.
    private static let previewSize: CGFloat = 128

    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    /// The hairline between the browse pane and the inspector. Internal for tests.
    private(set) var separator: NSBox?
    private var loadToken = 0
    /// Which cloud the shown objects live on. Event prediction is stated in the
    /// provider's own vocabulary, so with no provider connected there is nothing
    /// truthful to predict and the section is omitted.
    private var providerKind: ProviderKind?
    /// What's on show, so Show More can rebuild it without another round trip.
    private var shown: [StorageObject] = []
    private var shownMetadata: ObjectMetadata?

    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 16, left: Self.inset, bottom: 20, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        // Same rule as the sidebar: no scroller until the content overflows.
        scrollView.autohidesScrollers = true
        // Opaque, and the same colour the browse panes use.
        //
        // The window is `.fullSizeContentView` under a translucent unified toolbar, so
        // every pane extends behind the titlebar and whatever it paints there is what
        // the toolbar tints against. The browse panes paint `.controlBackgroundColor`;
        // this one painted nothing, so the toolbar picked up the window backdrop over
        // the inspector and the control background over the content — a visible seam in
        // the titlebar that moved with the inspector's width.
        //
        // The sidebar is deliberately left transparent: its vibrancy behind the
        // titlebar is the standard Mac look, and that seam lines up with the toolbar's
        // sidebar tracking separator.
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // A hairline down the inspector's leading edge, like the Finder's between its
        // columns and the preview. The split view's own divider is there to drag but
        // draws nothing on macOS 26, and with both panes painting the same background
        // the inspector otherwise ran straight on from the list with no edge at all.
        // It starts below the toolbar, as the Finder's does: the titlebar stays one
        // uninterrupted surface.
        let edge = NSBox()
        edge.boxType = .separator
        edge.translatesAutoresizingMaskIntoConstraints = false
        // A separator box decides it is horizontal while its frame is still empty, and
        // then asks for an intrinsic height of 1 at hugging priority 750 — above the
        // priority of a window resize, so the whole window got held at toolbar height.
        // The constraints below set its size; it should want nothing of its own.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            edge.setContentHuggingPriority(.init(1), for: orientation)
            edge.setContentCompressionResistancePriority(.init(1), for: orientation)
        }
        separator = edge

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(edge)
        view = container

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            edge.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            edge.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            edge.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),
        ])

        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        present(objects: [], provider: nil, containerName: nil)
    }

    // MARK: - Presentation

    /// Shows the selection: an empty state for none, full detail for one, and a
    /// Finder-style summary for several. Only a single selection is worth a HEAD —
    /// enriching N objects would mean N round trips for information the summary
    /// doesn't show.
    func present(objects: [StorageObject], provider: (any StorageProvider)?, containerName: String?) {
        loadToken += 1
        let token = loadToken
        providerKind = provider?.kind
        shown = objects
        shownMetadata = nil

        guard objects.count == 1 else {
            rebuildForMultiple(objects)
            return
        }
        let object = objects[0]
        rebuild(for: object, metadata: nil)

        guard !object.isPrefix, let provider, let containerName else { return }

        Task { @MainActor in
            let container = StorageContainer(name: containerName)
            guard let metadata = try? await provider.fetchMetadata(for: object, in: container) else { return }
            guard token == self.loadToken else { return }
            self.shownMetadata = metadata
            self.rebuild(for: object, metadata: metadata)
        }
    }

    // MARK: - Building
    //
    // Laid out after the Finder's preview pane: a large icon centred at the top, then
    // the name and a kind-and-size line flush left, then titled sections of rows with
    // the label on the left, the value on the right, and a hairline between rows.

    private func clear() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    /// Adds `view` spanning the pane between the stack's insets. `NSStackView` has no
    /// fill alignment for a vertical stack, so the width is pinned here; without it
    /// every row shrank to its content and the stack lined them all up on the right.
    private func addFullWidth(_ view: NSView, spacingAfter: CGFloat? = nil) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.inset).isActive = true
        if let spacingAfter { stack.setCustomSpacing(spacingAfter, after: view) }
    }

    private func rebuild(for object: StorageObject?, metadata: ObjectMetadata?) {
        clear()

        guard let object else {
            addFullWidth(emptyState())
            return
        }

        let type = StorageObject.utType(contentType: metadata?.contentType ?? object.contentType, key: object.key)
        let size = metadata?.size ?? object.size
        let icon = object.isPrefix ? NSWorkspace.shared.icon(for: .folder) : NSWorkspace.shared.icon(for: type)
        let kind = object.isPrefix ? "Folder" : (type.localizedDescription ?? "Document")
        addHeader(
            icon: icon,
            name: lastComponent(of: object.key),
            subtitle: object.isPrefix ? kind : "\(kind) – \(byteFormatter.string(fromByteCount: size))"
        )

        if object.isPrefix {
            addFullWidth(section("Information", rows: [Row("Path", object.key, wraps: false)]), spacingAfter: Self.sectionSpacing)
            return
        }

        // Kind and size are in the line under the name, as the Finder has them. The
        // rows start with what that line doesn't say, and "Show More" holds the
        // details only some people need.
        var rows: [Row] = []
        if let modified = metadata?.lastModified ?? object.lastModified {
            rows.append(Row("Modified", dateFormatter.string(from: modified)))
        }
        rows.append(Row("Tier", metadata?.storageClass ?? object.storageClass ?? "—"))
        rows.append(Row("Path", object.key, wraps: false))
        if StrataDefaults.inspectorShowsMore {
            rows.append(Row("Size", Self.exactSize(size)))
            rows.append(Row("Content Type", metadata?.contentType ?? object.contentType ?? "—", wraps: false))
            if let blobType = metadata?.blobType { rows.append(Row("Blob Type", blobType)) }
            if let etag = metadata?.etag ?? object.etag {
                rows.append(Row("ETag", Self.displayETag(etag), wraps: false))
            }
        }
        addFullWidth(section("Information", rows: rows, accessory: showMoreButton()), spacingAfter: Self.sectionSpacing)

        if let custom = metadata?.custom, !custom.isEmpty {
            let rows = custom.sorted { $0.key < $1.key }.map { Row($0.key, $0.value) }
            addFullWidth(section("Metadata", rows: rows), spacingAfter: Self.sectionSpacing)
        }

        if let providerKind {
            addFullWidth(writeEventSection(for: object, kind: providerKind), spacingAfter: Self.sectionSpacing)
        }

        addFullWidth(quickActions(multiple: false))
    }

    /// Finder's multiple selection: a stack of documents, how many, how big, and
    /// what mix.
    private func rebuildForMultiple(_ objects: [StorageObject]) {
        clear()

        guard !objects.isEmpty else {
            addFullWidth(emptyState())
            return
        }

        let folders = objects.filter(\.isPrefix)
        let blobs = objects.filter { !$0.isPrefix }
        // Folder sizes are unknown without a recursive walk, so the total covers the
        // blobs, and the rows say how many folders it leaves out.
        let totalBytes = blobs.reduce(Int64(0)) { $0 + $1.size }

        addHeader(
            icon: NSImage(named: NSImage.multipleDocumentsName) ?? NSWorkspace.shared.icon(for: .data),
            name: "\(objects.count) items",
            subtitle: blobs.isEmpty ? "Folders" : byteFormatter.string(fromByteCount: totalBytes)
        )

        var rows: [Row] = []
        if !folders.isEmpty { rows.append(Row("Folders", "\(folders.count)")) }
        if !blobs.isEmpty {
            rows.append(Row("Blobs", "\(blobs.count)"))
            if let largest = blobs.max(by: { $0.size < $1.size }) {
                rows.append(Row("Largest", "\(lastComponent(of: largest.key)) – \(byteFormatter.string(fromByteCount: largest.size))", wraps: false))
            }
        }
        addFullWidth(section("Information", rows: rows), spacingAfter: Self.sectionSpacing)

        // The differentiator still applies in bulk: re-uploading this selection emits
        // a mix of events, and which ones is exactly what the user wants to know.
        if !blobs.isEmpty {
            if let providerKind {
                addFullWidth(multipleWriteEventSection(for: blobs, kind: providerKind), spacingAfter: Self.sectionSpacing)
            }
            addFullWidth(quickActions(multiple: true))
        }
    }

    // MARK: - Header

    private func addHeader(icon: NSImage, name: String, subtitle: String) {
        // The icon is centred in the pane, like the Finder's preview, and as large as
        // the pane allows up to the size the Finder uses for a file with no preview.
        let image = NSImageView()
        image.image = icon
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        let well = NSView()
        well.addSubview(image)
        let side = image.widthAnchor.constraint(equalToConstant: Self.previewSize)
        side.priority = .defaultHigh
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: well.topAnchor),
            image.bottomAnchor.constraint(equalTo: well.bottomAnchor),
            image.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            image.widthAnchor.constraint(lessThanOrEqualTo: well.widthAnchor),
            image.heightAnchor.constraint(equalTo: image.widthAnchor),
            side,
        ])
        addFullWidth(well, spacingAfter: 14)

        let title = NSTextField(wrappingLabelWithString: name)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.isSelectable = true
        // A name is often one long token (`Suvida_Healthcare_ADT_260913.csv`), with no
        // spaces to wrap at. The Finder breaks those anywhere rather than cut them off.
        title.lineBreakStrategy = []
        title.cell?.lineBreakMode = .byCharWrapping
        addFullWidth(title, spacingAfter: 2)

        let detail = NSTextField(labelWithString: subtitle)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addFullWidth(detail, spacingAfter: Self.sectionSpacing)
    }

    // MARK: - Sections

    /// A titled group of rows. The title is in the Finder's style — bold, in the
    /// label colour, not small capitals — with an optional control on its right.
    private func section(_ title: String, rows: [Row], accessory: NSView? = nil) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .bold)
        heading.textColor = .labelColor

        let titleBar = NSStackView(views: [heading])
        titleBar.orientation = .horizontal
        titleBar.alignment = .firstBaseline
        if let accessory {
            titleBar.addView(accessory, in: .trailing)
        }

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 0
        container.addArrangedSubview(titleBar)
        titleBar.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        container.setCustomSpacing(4, after: titleBar)

        for (index, row) in rows.enumerated() {
            if index > 0 {
                let rule = hairline()
                container.addArrangedSubview(rule)
                rule.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
            }
            let view = self.row(row.label, row.value, wraps: row.wraps)
            container.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }
        return container
    }

    /// "Show More" / "Show Less", as in the Finder: a link-coloured text button that
    /// expands the Information section. The choice sticks, as it does there.
    private func showMoreButton() -> NSButton {
        let button = NSButton(
            title: StrataDefaults.inspectorShowsMore ? "Show Less" : "Show More",
            target: self,
            action: #selector(toggleShowMore(_:))
        )
        button.isBordered = false
        button.font = .systemFont(ofSize: 13)
        button.contentTintColor = .linkColor
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    @objc private func toggleShowMore(_ sender: Any?) {
        StrataDefaults.inspectorShowsMore.toggle()
        guard shown.count == 1 else { return }
        rebuild(for: shown[0], metadata: shownMetadata)
    }

    private func writeEventSection(for object: StorageObject, kind: ProviderKind) -> NSView {
        let event = UploadPlan(
            byteCount: object.size,
            target: .default(for: kind)
        ).predictedEvent

        let container = section(event.systemName, rows: [
            Row("Re-upload", event.operationSummary),
            Row("Emits", event.emissionSummary),
        ])

        let reassuring = event.confidence.isReassuring
        let statusImage = NSImageView()
        statusImage.image = NSImage(systemSymbolName: reassuring ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", accessibilityDescription: nil)
        statusImage.contentTintColor = reassuring ? .systemGreen : .systemOrange
        statusImage.setContentHuggingPriority(.required, for: .horizontal)

        let statusText = NSTextField(wrappingLabelWithString: event.confidence.message)
        statusText.font = .systemFont(ofSize: 11)
        statusText.textColor = .secondaryLabelColor

        let status = NSStackView(views: [statusImage, statusText])
        status.orientation = .horizontal
        status.alignment = .firstBaseline
        status.spacing = 6
        let rule = hairline()
        container.addArrangedSubview(rule)
        rule.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        container.setCustomSpacing(Self.rowPadding, after: rule)
        container.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        return container
    }

    /// Counts how many of the selected blobs would emit each `data.api` on re-upload.
    private func multipleWriteEventSection(for blobs: [StorageObject], kind: ProviderKind) -> NSView {
        let target = UploadTarget.default(for: kind)
        var counts: [String: Int] = [:]
        var systemName = ""
        for blob in blobs {
            let event = UploadPlan(byteCount: blob.size, target: target).predictedEvent
            systemName = event.systemName
            counts[event.eventName, default: 0] += 1
        }
        // Ties broken by name so the order doesn't wobble between selections of the
        // same shape — dictionary order isn't stable.
        let rows = counts.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) })
            .map { Row($0.key, "\($0.value) of \(blobs.count) on re-upload") }
        return section(systemName, rows: rows)
    }

    // MARK: - Quick actions

    /// The Finder ends its preview pane with the things you can do to the file, as
    /// round buttons with a caption. These go up the responder chain to the browser,
    /// the same way the context menu's items do.
    private func quickActions(multiple: Bool) -> NSView {
        var buttons: [NSButton] = []
        if !multiple {
            buttons.append(quickAction("Quick Look", symbol: "eye", action: #selector(BrowserSplitViewController.toggleQuickLook(_:))))
        }
        buttons.append(quickAction("Download", symbol: "arrow.down", action: #selector(BrowserSplitViewController.downloadSelection(_:))))
        buttons.append(quickAction("Download To…", symbol: "folder", action: #selector(BrowserSplitViewController.downloadSelectionTo(_:))))

        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 20
        row.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView()
        wrapper.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            row.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: wrapper.leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor),
        ])
        return wrapper
    }

    private func quickAction(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(), target: nil, action: action)
        button.isBordered = false
        button.imagePosition = .imageAbove
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = .secondaryLabelColor
        button.image = Self.ringed(symbol)
        return button
    }

    /// A symbol inside a thin circle, the Finder's quick-action look.
    private static func ringed(_ symbol: String) -> NSImage {
        let diameter: CGFloat = 30
        let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            NSColor.black.setStroke()
            ring.stroke()
            if let glyph {
                let origin = NSPoint(x: rect.midX - glyph.size.width / 2, y: rect.midY - glyph.size.height / 2)
                glyph.draw(in: NSRect(origin: origin, size: glyph.size))
            }
            return true
        }
        // A template, so the button's tint colours it and it follows the appearance.
        image.isTemplate = true
        return image
    }

    // MARK: - Empty state

    private func emptyState() -> NSView {
        let label = NSTextField(labelWithString: "No Selection")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView()
        wrapper.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 120),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        return wrapper
    }

    // MARK: - Row primitives

    private func hairline() -> NSView {
        let rule = NSBox()
        rule.boxType = .separator
        return rule
    }

    /// Label on the left in the secondary colour, value on the right in the primary,
    /// as the Finder's rows are.
    ///
    /// `wraps: false` is for single-token values — paths, MIME types, ETags. They
    /// have no word boundaries to break on, so wrapping them shatters the token
    /// mid-word across four lines; the Finder truncates such values and keeps the
    /// whole string reachable by selection and tooltip.
    private func row(_ label: String, _ value: String, wraps: Bool = true) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 12)
        labelField.textColor = .secondaryLabelColor
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.setContentHuggingPriority(.required, for: .horizontal)
        labelField.setContentCompressionResistancePriority(.required, for: .horizontal)

        let valueField = wraps
            ? NSTextField(wrappingLabelWithString: value)
            : NSTextField(labelWithString: value)
        valueField.font = .systemFont(ofSize: 12)
        valueField.textColor = .labelColor
        valueField.alignment = .right
        valueField.isSelectable = true
        valueField.translatesAutoresizingMaskIntoConstraints = false
        valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if !wraps {
            valueField.lineBreakMode = .byTruncatingMiddle
            valueField.cell?.usesSingleLineMode = true
            valueField.toolTip = value
            // Without this the intrinsic width of a long token wins and pushes the
            // pane wider instead of truncating.
            valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let row = NSView()
        row.addSubview(labelField)
        row.addSubview(valueField)
        let pad = Self.rowPadding
        NSLayoutConstraint.activate([
            labelField.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            labelField.topAnchor.constraint(equalTo: row.topAnchor, constant: pad),
            labelField.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -pad),
            valueField.leadingAnchor.constraint(greaterThanOrEqualTo: labelField.trailingAnchor, constant: 12),
            valueField.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            valueField.firstBaselineAnchor.constraint(equalTo: labelField.firstBaselineAnchor),
            valueField.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -pad),
        ])
        return row
    }

    /// "7,024 bytes" — the size to the byte, which the kind line under the name
    /// rounds. The Finder's Get Info gives both the same way.
    static func exactSize(_ bytes: Int64) -> String {
        let number = NumberFormatter.localizedString(from: NSNumber(value: bytes), number: .decimal)
        return bytes == 1 ? "1 byte" : "\(number) bytes"
    }

    /// Azure returns the ETag as an HTTP entity tag, quotes included
    /// (`"0x8DEE126C27919F8"`). The quotes are protocol syntax, not part of the
    /// value, and showing them invites copying them into a query by mistake.
    /// Internal rather than private so `@testable` can reach it.
    static func displayETag(_ etag: String) -> String {
        var trimmed = etag.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("W/") { trimmed.removeFirst(2) }   // weak validator
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private func lastComponent(of key: String) -> String {
        var trimmed = key
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}
