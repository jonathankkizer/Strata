import AppKit

/// A thin determinate progress ring, drawn top-anchored and clockwise. Used inside
/// the toolbar button to show aggregate transfer progress.
@MainActor
final class CircularProgressView: NSView {

    var progress: Double = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth: CGFloat = 2.5
        let rect = bounds.insetBy(dx: lineWidth / 2 + 1, dy: lineWidth / 2 + 1)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = lineWidth
        NSColor.tertiaryLabelColor.setStroke()
        track.stroke()

        guard progress > 0 else { return }
        let startAngle: CGFloat = 90
        let endAngle = startAngle - CGFloat(min(max(progress, 0), 1) * 360)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        NSColor.controlAccentColor.setStroke()
        arc.stroke()
    }
}

/// Toolbar button for the transfer queue: a glyph when idle, an aggregate progress
/// ring while transfers run. Clicking opens the transfers popover.
@MainActor
final class TransfersToolbarButton: NSButton {

    /// The queue carries uploads *and* downloads, so the glyph has to read as
    /// two-way movement — Apple's own semantic for that is `arrow.up.arrow.down`
    /// (System Settings' Transfer or Reset, network throughput). An up-only tray
    /// would both under-describe the queue and echo Upload's `arrow.up.doc` two
    /// items away in the same toolbar. Deliberately not a `.circle` variant: the
    /// active state swaps in a progress ring, and a circled glyph would read as a
    /// second, static ring.
    private static let idleSymbolName = "arrow.up.arrow.down"

    private let ring = CircularProgressView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .toolbar
        setButtonType(.momentaryPushIn)
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: Self.idleSymbolName, accessibilityDescription: "Transfers")

        ring.translatesAutoresizingMaskIntoConstraints = false
        ring.isHidden = true
        addSubview(ring)
        NSLayoutConstraint.activate([
            ring.centerXAnchor.constraint(equalTo: centerXAnchor),
            ring.centerYAnchor.constraint(equalTo: centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 17),
            ring.heightAnchor.constraint(equalToConstant: 17),
        ])
        setAccessibilityLabel("Transfers")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(active: Bool, fraction: Double) {
        ring.isHidden = !active
        if active {
            image = nil
            ring.progress = fraction
            setAccessibilityValue("\(Int(fraction * 100))% complete")
        } else {
            image = NSImage(systemSymbolName: Self.idleSymbolName, accessibilityDescription: "Transfers")
            setAccessibilityValue(nil)
        }
    }
}
