import AppKit

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
            stack.addArrangedSubview(placeholder("No selection"))
            return
        }

        stack.addArrangedSubview(headerView(for: object))

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

    private func headerView(for object: StorageObject) -> NSView {
        let icon = NSImageView()
        let symbol = object.isPrefix ? "folder.fill" : "doc.fill"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        icon.contentTintColor = object.isPrefix ? .controlAccentColor : .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let name = NSTextField(wrappingLabelWithString: lastComponent(of: object.key))
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.isSelectable = true

        let subtitle = NSTextField(labelWithString: object.isPrefix ? "Folder" : (object.contentType ?? "Blob"))
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        let text = NSStackView(views: [name, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let header = NSStackView(views: [icon, text])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 10
        return header
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
            : "Won’t match standard BlobCreated filters.")
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

    private func placeholder(_ text: String) -> NSView {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 12)
        return field
    }

    private func lastComponent(of key: String) -> String {
        var trimmed = key
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}
