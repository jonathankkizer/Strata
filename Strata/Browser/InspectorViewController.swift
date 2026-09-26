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

    /// Between rows within a section. Needs to stay comfortably larger than the
    /// line spacing inside a wrapped value, or a multi-line value and the row below
    /// it read as one block.
    private static let rowSpacing: CGFloat = 7

    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    /// The hairline between the browse pane and the inspector. Internal for tests.
    private(set) var separator: NSBox?
    private var loadToken = 0
    /// Which cloud the shown objects live on. Event prediction is stated in the
    /// provider's own vocabulary, so with no provider connected there is nothing
    /// truthful to predict and the section is omitted.
    private var providerKind: ProviderKind?

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
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
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
            self.rebuild(for: object, metadata: metadata)
        }
    }

    // MARK: - Building

    private func rebuild(for object: StorageObject?, metadata: ObjectMetadata?) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard let object else {
            stack.alignment = .centerX
            stack.addArrangedSubview(emptyState())
            return
        }

        // .width stretches arranged subviews to the inspector width, so the header's
        // centerX actually centers (sections keep their content leading-aligned).
        stack.alignment = .width
        stack.addArrangedSubview(headerView(for: object, metadata: metadata))

        if object.isPrefix {
            stack.addArrangedSubview(section("Kind", rows: [Row("Type", "Folder (prefix)")]))
            return
        }

        // No "Name" row: the header above already shows the filename, at a size
        // meant to be read. Repeating it here cost four wrapped lines to say the
        // same thing — Finder's Get Info doesn't repeat it either.
        var general: [Row] = [
            Row("Path", object.key, wraps: false),
            Row("Size", byteFormatter.string(fromByteCount: metadata?.size ?? object.size)),
            Row("Tier", metadata?.storageClass ?? object.storageClass ?? "—"),
            Row("Type", metadata?.contentType ?? object.contentType ?? "—", wraps: false),
        ]
        if let blobType = metadata?.blobType { general.append(Row("Blob Type", blobType)) }
        if let modified = metadata?.lastModified ?? object.lastModified {
            general.append(Row("Modified", dateFormatter.string(from: modified)))
        }
        if let etag = metadata?.etag ?? object.etag {
            general.append(Row("ETag", Self.displayETag(etag), wraps: false))
        }
        stack.addArrangedSubview(section("General", rows: general))

        if let custom = metadata?.custom, !custom.isEmpty {
            let rows = custom.sorted { $0.key < $1.key }.map { Row($0.key, $0.value) }
            stack.addArrangedSubview(section("Metadata", rows: rows))
        }

        if let providerKind {
            stack.addArrangedSubview(writeEventSection(for: object, kind: providerKind))
        }
    }

    /// Finder's multiple-selection Get Info: how many, how big, and what mix.
    private func rebuildForMultiple(_ objects: [StorageObject]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard !objects.isEmpty else {
            stack.alignment = .centerX
            stack.addArrangedSubview(emptyState())
            return
        }

        let folders = objects.filter(\.isPrefix)
        let blobs = objects.filter { !$0.isPrefix }
        // Folder sizes are unknown without a recursive walk, so the total covers the
        // blobs and the caption says so rather than quietly under-reporting.
        let totalBytes = blobs.reduce(Int64(0)) { $0 + $1.size }

        stack.alignment = .width
        stack.addArrangedSubview(multipleHeaderView(count: objects.count, totalBytes: totalBytes, blobCount: blobs.count))

        var rows: [Row] = [Row("Items", "\(objects.count)")]
        if !folders.isEmpty {
            rows.append(Row("Folders", "\(folders.count)"))
        }
        if !blobs.isEmpty {
            rows.append(Row("Blobs", "\(blobs.count)"))
            rows.append(Row("Total Size", byteFormatter.string(fromByteCount: totalBytes)))
            if let largest = blobs.max(by: { $0.size < $1.size }) {
                rows.append(Row("Largest", "\(lastComponent(of: largest.key)) — \(byteFormatter.string(fromByteCount: largest.size))"))
            }
        }
        stack.addArrangedSubview(section("Selection", rows: rows))

        // The differentiator still applies in bulk: re-uploading this selection emits
        // a mix of events, and which ones is exactly what the user wants to know.
        if !blobs.isEmpty, let providerKind {
            stack.addArrangedSubview(multipleWriteEventSection(for: blobs, kind: providerKind))
        }
    }

    private func multipleHeaderView(count: Int, totalBytes: Int64, blobCount: Int) -> NSView {
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 44, weight: .thin)
        icon.contentTintColor = .secondaryLabelColor

        let name = NSTextField(labelWithString: "\(count) items selected")
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.alignment = .center

        let subtitle = NSTextField(labelWithString: blobCount == 0
            ? "Folders"
            : byteFormatter.string(fromByteCount: totalBytes))
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        let container = NSStackView(views: [icon, name, subtitle])
        container.orientation = .vertical
        container.alignment = .centerX
        container.spacing = 6
        container.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 8),
            container.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -8),
            container.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: wrapper.leadingAnchor),
            container.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor),
        ])
        return wrapper
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

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .width
        container.spacing = Self.rowSpacing
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(sectionHeader(systemName))

        // Ties broken by name so the order doesn't wobble between selections of the
        // same shape — dictionary order isn't stable.
        for (name, count) in counts.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
            container.addArrangedSubview(row(name, "\(count) of \(blobs.count) on re-upload"))
        }
        return container
    }

    // MARK: - Sections

    private func headerView(for object: StorageObject, metadata: ObjectMetadata?) -> NSView {
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown

        if object.isPrefix {
            icon.image = NSWorkspace.shared.icon(for: .folder)
        } else {
            // Prefer metadata contentType > listing contentType > filename extension > generic data.
            // Quick Look preview of actual contents awaits a download path.
            let resolvedType = contentType(for: object, metadata: metadata)
            icon.image = NSWorkspace.shared.icon(for: resolvedType)
        }
        icon.image?.size = NSSize(width: 64, height: 64)
        icon.frame = NSRect(origin: .zero, size: NSSize(width: 64, height: 64))

        let name = NSTextField(wrappingLabelWithString: lastComponent(of: object.key))
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.alignment = .center
        name.isSelectable = true

        let subtitleString: String
        if object.isPrefix {
            subtitleString = "Folder"
        } else {
            let resolvedType = contentType(for: object, metadata: metadata)
            let kind = resolvedType.localizedDescription
                ?? metadata?.contentType
                ?? object.contentType
                ?? "Blob"
            let effectiveSize = metadata?.size ?? object.size
            let sizeString = byteFormatter.string(fromByteCount: effectiveSize)
            subtitleString = "\(kind) — \(sizeString)"
        }

        let subtitle = NSTextField(labelWithString: subtitleString)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        let container = NSStackView(views: [icon, name, subtitle])
        container.orientation = .vertical
        container.alignment = .centerX
        container.spacing = 6
        // Stretch to fill the inspector width so centering works.
        container.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 8),
            container.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -8),
            container.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: wrapper.leadingAnchor),
            container.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor),
        ])
        return wrapper
    }

    /// Resolves the best available UTType for a blob, falling back gracefully.
    private func contentType(for object: StorageObject, metadata: ObjectMetadata?) -> UTType {
        let mimeString = metadata?.contentType ?? object.contentType
        if let mime = mimeString, let utType = UTType(mimeType: mime) {
            return utType
        }
        let ext = (object.key as NSString).pathExtension
        if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
            return utType
        }
        return .data
    }

    private func writeEventSection(for object: StorageObject, kind: ProviderKind) -> NSView {
        let event = UploadPlan(
            byteCount: object.size,
            target: .default(for: kind)
        ).predictedEvent

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .width
        container.spacing = Self.rowSpacing
        container.translatesAutoresizingMaskIntoConstraints = false

        container.addArrangedSubview(sectionHeader(event.systemName))
        container.addArrangedSubview(row("Re-upload", event.operationSummary))
        container.addArrangedSubview(row("Emits", event.emissionSummary))

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
        // Indented to the value column: this line elaborates on "Emits" above it,
        // and starting it out in the label gutter made it look like a fourth row
        // whose label had gone missing.
        status.edgeInsets = NSEdgeInsets(top: 0, left: Self.labelColumnWidth + 8, bottom: 0, right: 0)
        container.addArrangedSubview(status)
        return container
    }

    private func section(_ title: String, rows: [Row]) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        // `.width`, not `.leading`: rows have to span the pane for the value column
        // to know how much room it has (and so truncating values can truncate).
        container.alignment = .width
        container.spacing = Self.rowSpacing
        container.addArrangedSubview(sectionHeader(title))
        for row in rows {
            container.addArrangedSubview(self.row(row.label, row.value, wraps: row.wraps))
        }
        return container
    }

    // MARK: - Empty state

    private func emptyState() -> NSView {
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .thin)
        iconView.contentTintColor = .tertiaryLabelColor

        let label = NSTextField(labelWithString: "No Selection")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .center

        let container = NSStackView(views: [iconView, label])
        container.orientation = .vertical
        container.alignment = .centerX
        container.spacing = 10
        container.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(container)
        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            container.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 48),
            container.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: wrapper.leadingAnchor),
            container.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor),
        ])
        return wrapper
    }

    // MARK: - Row primitives

    private func sectionHeader(_ title: String) -> NSView {
        let field = NSTextField(labelWithString: title.uppercased())
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = .secondaryLabelColor
        return field
    }

    /// Width of the right-aligned label gutter. Sized to the longest label actually
    /// used ("Blob Type", "Total Size") and no wider: the inspector is a narrow,
    /// user-resizable pane, and every point spent here comes straight out of the
    /// value column, which is what forces values to wrap.
    private static let labelColumnWidth: CGFloat = 62

    /// `wraps: false` is for single-token values — paths, MIME types, ETags. They
    /// have no word boundaries to break on, so wrapping them shatters the token
    /// mid-word across four lines; Finder's Get Info truncates such values (its
    /// "Where:" row) and keeps the whole string reachable by selection and tooltip.
    private func row(_ label: String, _ value: String, wraps: Bool = true) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.alignment = .right
        labelField.font = .systemFont(ofSize: 11)
        labelField.textColor = .secondaryLabelColor
        labelField.setContentHuggingPriority(.required, for: .horizontal)
        labelField.setContentCompressionResistancePriority(.required, for: .horizontal)
        labelField.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth).isActive = true

        let valueField = wraps
            ? NSTextField(wrappingLabelWithString: value)
            : NSTextField(labelWithString: value)
        valueField.font = .systemFont(ofSize: 12)
        valueField.isSelectable = true
        valueField.textColor = .labelColor
        if !wraps {
            valueField.lineBreakMode = .byTruncatingMiddle
            valueField.cell?.usesSingleLineMode = true
            valueField.toolTip = value
            // Without this the intrinsic width of a long token wins and pushes the
            // pane wider instead of truncating.
            valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let row = NSStackView(views: [labelField, valueField])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.distribution = .fill
        valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
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
