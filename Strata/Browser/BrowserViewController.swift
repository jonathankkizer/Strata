import AppKit

/// Dual-pane browser content. v1 replaces each placeholder pane with an
/// NSOutlineView (bucket/prefix tree) + NSTableView (objects) and wires
/// cross-provider drag-and-drop between the panes. Scaffolded here with two
/// placeholder panes inside a real NSSplitView so the window is live.
@MainActor
final class BrowserViewController: NSViewController {

    override func loadView() {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false

        let left = makePane(title: "Provider A", subtitle: "Connect Amazon S3 or Azure Blob Storage")
        let right = makePane(title: "Provider B", subtitle: "Drag objects across providers here")
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)

        view = split
        view.frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
    }

    private func makePane(title: String, subtitle: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.alignment = .center

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 0

        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let pane = NSView()
        pane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: pane.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: pane.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor, constant: -16),
            pane.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        return pane
    }
}
