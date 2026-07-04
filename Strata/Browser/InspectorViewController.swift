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

    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    private var loadToken = 0

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
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true

        view = scrollView

        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        present(object: nil, provider: nil, containerName: nil)
    }

    // MARK: - Presentation

    func present(object: StorageObject?, provider: (any StorageProvider)?, containerName: String?) {
        loadToken += 1
        let token = loadToken
        rebuild(for: object, metadata: nil)

        guard let object, !object.isPrefix, let provider, let containerName else { return }

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
            stack.addArrangedSubview(section("Kind", rows: [("Type", "Folder (prefix)")]))
            return
        }

        var general: [(String, String)] = [
            ("Name", lastComponent(of: object.key)),
            ("Path", object.key),
            ("Size", byteFormatter.string(fromByteCount: metadata?.size ?? object.size)),
            ("Tier", metadata?.storageClass ?? object.storageClass ?? "—"),
            ("Type", metadata?.contentType ?? object.contentType ?? "—"),
        ]
        if let blobType = metadata?.blobType { general.append(("Blob Type", blobType)) }
        if let modified = metadata?.lastModified ?? object.lastModified {
            general.append(("Modified", dateFormatter.string(from: modified)))
        }
        if let etag = metadata?.etag ?? object.etag { general.append(("ETag", etag)) }
        stack.addArrangedSubview(section("General", rows: general))

        if let custom = metadata?.custom, !custom.isEmpty {
            let rows = custom.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            stack.addArrangedSubview(section("Metadata", rows: rows))
        }

        stack.addArrangedSubview(eventGridSection(for: object))
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

    private func eventGridSection(for object: StorageObject) -> NSView {
        let plan = UploadPlan(byteCount: object.size, endpoint: .blob)
        let api = plan.predictedCommitAPI
        let operation = api == .putBlob ? "Put Blob (single-shot)" : "Put Block List (staged)"

        var container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        container.translatesAutoresizingMaskIntoConstraints = false

        container.addArrangedSubview(sectionHeader("Event Grid"))
        container.addArrangedSubview(row("Re-upload", operation))
        container.addArrangedSubview(row("Emits", "BlobCreated · api: \(api.rawValue)"))

        let fires = api.firesBlobCreatedOnCommit
        let statusImage = NSImageView()
        statusImage.image = NSImage(systemSymbolName: fires ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", accessibilityDescription: nil)
        statusImage.contentTintColor = fires ? .systemGreen : .systemOrange
        statusImage.setContentHuggingPriority(.required, for: .horizontal)

        let statusText = NSTextField(wrappingLabelWithString: fires
            ? "Fires standard BlobCreated subscriptions."
            : "Won't match standard BlobCreated filters.")
        statusText.font = .systemFont(ofSize: 11)
        statusText.textColor = .secondaryLabelColor

        let status = NSStackView(views: [statusImage, statusText])
        status.orientation = .horizontal
        status.alignment = .firstBaseline
        status.spacing = 6
        container.addArrangedSubview(status)
        return container
    }

    private func section(_ title: String, rows pairs: [(String, String)]) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 5
        container.addArrangedSubview(sectionHeader(title))
        for (label, value) in pairs {
            container.addArrangedSubview(row(label, value))
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

    private func row(_ label: String, _ value: String) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.alignment = .right
        labelField.font = .systemFont(ofSize: 11)
        labelField.textColor = .secondaryLabelColor
        labelField.setContentHuggingPriority(.required, for: .horizontal)
        labelField.setContentCompressionResistancePriority(.required, for: .horizontal)
        labelField.widthAnchor.constraint(equalToConstant: 78).isActive = true

        let valueField = NSTextField(wrappingLabelWithString: value)
        valueField.font = .systemFont(ofSize: 12)
        valueField.isSelectable = true
        valueField.textColor = .labelColor

        let row = NSStackView(views: [labelField, valueField])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.distribution = .fill
        valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func lastComponent(of key: String) -> String {
        var trimmed = key
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}
