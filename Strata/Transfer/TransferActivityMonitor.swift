import AppKit
import UserNotifications

/// Shows transfer activity outside the window: a count and a progress bar on the Dock
/// icon while anything is moving, and a notification when a batch finishes while
/// Strata is in the background. Owned by the app delegate for the app's lifetime.
@MainActor
final class TransferActivityMonitor {

    /// Transfers that finished since the queue last went idle — one notification's
    /// worth.
    private var batch: [TransferSummary.Outcome] = []
    /// Terminal transfers already counted, so a queue change doesn't count them twice.
    private var counted = Set<UUID>()
    private var dockView: DockProgressView?
    private var hasRequestedAuthorization = false

    func start() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(queueChanged), name: .transferQueueDidChange, object: nil)
        center.addObserver(self, selector: #selector(progressChanged), name: .transferQueueProgress, object: nil)
        center.addObserver(self, selector: #selector(enqueued), name: .transferQueueDidEnqueue, object: nil)
    }

    // MARK: - Dock

    @objc private func progressChanged() {
        updateDock()
    }

    private func updateDock() {
        let queue = TransferQueue.shared
        let tile = NSApp.dockTile
        guard queue.hasActive else {
            tile.badgeLabel = nil
            if dockView != nil {
                dockView = nil
                tile.contentView = nil
            }
            tile.display()
            return
        }
        tile.badgeLabel = String(queue.activeCount)
        let view = dockView ?? DockProgressView(frame: NSRect(origin: .zero, size: tile.size))
        if dockView == nil {
            dockView = view
            tile.contentView = view
        }
        view.progress = queue.aggregateFraction
        tile.display()
    }

    // MARK: - Notifications

    /// Asked for when the first transfer of the session starts, which is when the
    /// question makes sense, rather than at launch.
    @objc private func enqueued() {
        guard !hasRequestedAuthorization, StrataDefaults.notifyWhenTransfersFinish,
              !UpdateCoordinator.isRunningTests else { return }
        hasRequestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @objc private func queueChanged() {
        updateDock()
        let queue = TransferQueue.shared
        for item in queue.transfers where !counted.contains(item.id) {
            switch item.state {
            case .completed:
                counted.insert(item.id)
                batch.append(.init(direction: item.direction, fileName: item.fileName, failure: nil))
            case .failed(let reason):
                counted.insert(item.id)
                batch.append(.init(direction: item.direction, fileName: item.fileName, failure: reason))
            case .cancelled:
                counted.insert(item.id)
            case .queued, .running:
                break
            }
        }
        // A retried transfer is active again and may finish again.
        for item in queue.transfers where item.isActive { counted.remove(item.id) }

        guard !queue.hasActive, !batch.isEmpty else { return }
        let finished = batch
        batch = []
        guard !NSApp.isActive, StrataDefaults.notifyWhenTransfersFinish,
              !UpdateCoordinator.isRunningTests,
              let summary = TransferSummary.make(finished) else { return }
        post(summary)
    }

    private func post(_ summary: TransferSummary) {
        let content = UNMutableNotificationContent()
        content.title = summary.title
        content.body = summary.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// The app icon with a progress bar across its lower edge — what the Dock shows while
/// transfers run, the way the Finder shows a copy's progress.
private final class DockProgressView: NSView {

    var progress: Double = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)

        let inset = bounds.width * 0.12
        let height = max(bounds.height * 0.1, 8)
        let track = NSRect(x: inset, y: bounds.height * 0.1, width: bounds.width - inset * 2, height: height)
        let radius = height / 2

        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let fraction = min(max(progress, 0), 1)
        guard fraction > 0 else { return }
        var bar = track.insetBy(dx: 1.5, dy: 1.5)
        bar.size.width = max(bar.height, bar.width * fraction)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
    }
}
