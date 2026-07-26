import AppKit

/// One transfer row: icon, name + `data.api` badge, destination, a live progress
/// bar (while active) or status text, and a stop/retry control.
@MainActor
final class TransferRowView: NSView {

    var onAction: (() -> Void)?

    private let icon = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let badgeBox = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let destinationField = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let statusField = NSTextField(labelWithString: "")
    private let actionButton = NSButton()

    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        refreshBadgeColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBadgeColor()
    }

    private func build() {
        icon.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        nameField.font = .systemFont(ofSize: 12, weight: .medium)
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        badgeLabel.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeBox.wantsLayer = true
        badgeBox.layer?.cornerRadius = 4
        badgeBox.translatesAutoresizingMaskIntoConstraints = false
        badgeBox.addSubview(badgeLabel)
        badgeBox.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            badgeLabel.topAnchor.constraint(equalTo: badgeBox.topAnchor, constant: 1),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeBox.bottomAnchor, constant: -1),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeBox.leadingAnchor, constant: 5),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeBox.trailingAnchor, constant: -5),
        ])

        let titleRow = NSStackView(views: [nameField, badgeBox])
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .centerY

        destinationField.font = .systemFont(ofSize: 10)
        destinationField.textColor = .secondaryLabelColor
        destinationField.lineBreakMode = .byTruncatingHead

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        statusField.font = .systemFont(ofSize: 10)
        statusField.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [titleRow, destinationField, progressBar, statusField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false
        progressBar.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true

        actionButton.isBordered = false
        actionButton.imagePosition = .imageOnly
        actionButton.target = self
        actionButton.action = #selector(actionClicked)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.setContentHuggingPriority(.required, for: .horizontal)

        let outer = NSStackView(views: [icon, textStack, actionButton])
        outer.orientation = .horizontal
        outer.alignment = .centerY
        outer.spacing = 10
        outer.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 10)
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.group)
    }

    func update(with item: TransferItem) {
        nameField.stringValue = item.fileName
        // Uploads read "to <remote folder>", downloads "to <local folder>".
        destinationField.stringValue = item.destination
        icon.image = NSImage(
            systemSymbolName: item.direction == .upload ? "arrow.up.doc" : "arrow.down.doc",
            accessibilityDescription: item.direction == .upload ? "Upload" : "Download"
        )
        // Only uploads emit a storage event, so only uploads carry the api badge.
        if let api = item.predictedAPI {
            badgeLabel.stringValue = api.rawValue
            badgeBox.isHidden = false
        } else {
            badgeLabel.stringValue = ""
            badgeBox.isHidden = true
        }

        switch item.state {
        case .queued:
            progressBar.isHidden = false
            progressBar.doubleValue = 0
            statusField.stringValue = "Waiting…"
            statusField.textColor = .secondaryLabelColor
            configureAction(symbol: "stop.circle", tint: .secondaryLabelColor, enabled: true, tooltip: "Cancel")
        case .running:
            progressBar.isHidden = false
            progressBar.doubleValue = item.fractionCompleted
            statusField.stringValue = "\(byteFormatter.string(fromByteCount: item.bytesTransferred)) of \(byteFormatter.string(fromByteCount: item.byteCount))"
            statusField.textColor = .secondaryLabelColor
            configureAction(symbol: "stop.circle", tint: .secondaryLabelColor, enabled: true, tooltip: "Cancel")
        case .completed:
            progressBar.isHidden = true
            statusField.stringValue = "Completed · \(byteFormatter.string(fromByteCount: item.byteCount))"
            statusField.textColor = .systemGreen
            if item.canRevealInFinder {
                configureAction(symbol: "magnifyingglass.circle", tint: .controlAccentColor, enabled: true, tooltip: "Show in Finder")
            } else {
                configureAction(symbol: "checkmark.circle.fill", tint: .systemGreen, enabled: false, tooltip: nil)
            }
        case .cancelled:
            progressBar.isHidden = true
            statusField.stringValue = "Cancelled"
            statusField.textColor = .secondaryLabelColor
            configureAction(symbol: "arrow.clockwise.circle", tint: .controlAccentColor, enabled: true, tooltip: "Retry")
        case .failed(let reason):
            progressBar.isHidden = true
            statusField.stringValue = "Failed · \(reason)"
            statusField.textColor = .systemRed
            configureAction(symbol: "arrow.clockwise.circle", tint: .controlAccentColor, enabled: true, tooltip: "Retry")
        }
        let verb = item.direction == .upload ? "Upload" : "Download"
        setAccessibilityLabel("\(verb), \(item.fileName), \(statusField.stringValue)")
    }

    private func configureAction(symbol: String, tint: NSColor, enabled: Bool, tooltip: String?) {
        actionButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        actionButton.contentTintColor = tint
        actionButton.isEnabled = enabled
        actionButton.toolTip = tooltip
        actionButton.setAccessibilityLabel(tooltip)
    }

    private func refreshBadgeColor() {
        badgeBox.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }

    @objc private func actionClicked() {
        onAction?()
    }
}
