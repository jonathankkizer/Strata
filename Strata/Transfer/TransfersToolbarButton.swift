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

/// Toolbar button for the transfer queue: a tray icon when idle, an aggregate
/// progress ring while transfers run. Clicking opens the transfers popover.
@MainActor
final class TransfersToolbarButton: NSButton {

    private let ring = CircularProgressView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .toolbar
        setButtonType(.momentaryPushIn)
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "tray.and.arrow.up", accessibilityDescription: "Transfers")

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
            image = NSImage(systemSymbolName: "tray.and.arrow.up", accessibilityDescription: "Transfers")
            setAccessibilityValue(nil)
        }
    }
}
