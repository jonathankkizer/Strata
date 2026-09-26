import Foundation

/// App-wide transfer queue — uploads and downloads share one queue, one concurrency
/// budget, and one progress ring, the way a Mac file-transfer client should. Reports
/// real byte progress and supports cancel and retry. Cancellation rides on structured
/// concurrency: each transfer runs in a `Task`, and cancelling it cancels the
/// in-flight URLSession task. MainActor-isolated; observers subscribe via
/// NotificationCenter so the toolbar ring and the popover stay in sync.
@MainActor
final class TransferQueue {

    static let shared = TransferQueue()

    private(set) var transfers: [TransferItem] = []
    private let maxConcurrent = 2
    private var progressPostScheduled = false

    private init() {}

    // MARK: - Public API

    func enqueueUpload(
        fileURL: URL,
        key: String,
        container: StorageContainer,
        destination: String,
        contentType: String?,
        plan: UploadPlan,
        provider: any StorageProvider
    ) {
        enqueue(TransferItem(
            uploadFrom: fileURL,
            key: key,
            container: container,
            destination: destination,
            contentType: contentType,
            plan: plan,
            provider: provider
        ))
    }

    /// Enqueues a download of `object` to `destinationURL`. `onFinish` fires once the
    /// transfer reaches a terminal state — the drag-to-Finder file promise uses it to
    /// tell Finder the file has actually landed.
    func enqueueDownload(
        object: StorageObject,
        container: StorageContainer,
        to destinationURL: URL,
        provider: any StorageProvider,
        onFinish: ((Error?) -> Void)? = nil
    ) {
        let item = TransferItem(
            downloadKey: object.key,
            container: container,
            to: destinationURL,
            byteCount: object.size,
            contentType: object.contentType,
            provider: provider
        )
        item.onFinish = onFinish
        enqueue(item)
    }

    /// Local paths that downloads still own but may not have written yet. Collision
    /// checks must treat these as taken: the file isn't on disk until the transfer
    /// finishes, so `fileExists` alone would let a second download of another
    /// `data.csv` pick the same name and overwrite the first. Unfinished includes failed
    /// and cancelled items, since Retry writes back to the same place.
    var claimedDownloadPaths: Set<String> {
        Set(transfers.lazy
            .filter { $0.direction == .download && $0.state != .completed }
            .map { $0.localURL.standardizedFileURL.path })
    }

    private func enqueue(_ item: TransferItem) {
        transfers.insert(item, at: 0)   // newest on top
        postChange()
        NotificationCenter.default.post(name: .transferQueueDidEnqueue, object: self)
        startEligible()
    }

    func cancel(_ item: TransferItem) {
        guard item.isActive else { return }
        item.task?.cancel()
        if item.state == .queued {
            item.state = .cancelled
            postChange()
            startEligible()
        }
    }

    func retry(_ item: TransferItem) {
        guard item.isRetryable else { return }
        item.bytesTransferred = 0
        item.state = .queued
        postChange()
        startEligible()
    }

    func clearFinished() {
        transfers.removeAll { !$0.isActive }
        postChange()
    }

    // MARK: - Aggregate state (for the toolbar ring)

    var hasActive: Bool { transfers.contains { $0.isActive } }
    var activeCount: Int { transfers.filter { $0.isActive }.count }

    var aggregateFraction: Double {
        let inflight = transfers.filter { $0.state == .running || $0.state == .queued }
        let total = inflight.reduce(Int64(0)) { $0 + $1.byteCount }
        guard total > 0 else { return 0 }
        let sent = inflight.reduce(Int64(0)) { $0 + $1.bytesTransferred }
        return Double(sent) / Double(total)
    }

    // MARK: - Driving

    private var runningCount: Int { transfers.filter { $0.state == .running }.count }

    private func startEligible() {
        while runningCount < maxConcurrent, let next = transfers.last(where: { $0.state == .queued }) {
            start(next)
        }
    }

    private func start(_ item: TransferItem) {
        item.state = .running
        item.bytesTransferred = 0
        postChange()

        let id = item.id
        let total = item.byteCount

        item.task = Task { [weak self] in
            // The service's own expected-total is ignored in favour of the size we
            // already know: a download response may omit Content-Length (-1), and the
            // staged upload path reports offsets against the whole file, not the block.
            let progress: @Sendable (Int64, Int64) -> Void = { sent, _ in
                Task { @MainActor in TransferQueue.shared.updateProgress(id: id, sent: sent, total: total) }
            }

            var failure: Error?
            do {
                switch item.direction {
                case .upload:
                    guard let plan = item.plan else { throw StorageProviderError.notImplemented }
                    try await item.provider.upload(
                        from: item.localURL,
                        toKey: item.key,
                        in: item.container,
                        contentType: item.contentType,
                        plan: plan,
                        onProgress: progress
                    )
                case .download:
                    try await item.provider.download(
                        fromKey: item.key,
                        in: item.container,
                        to: item.localURL,
                        onProgress: progress
                    )
                }
                item.bytesTransferred = item.byteCount
                item.state = .completed
            } catch is CancellationError {
                item.state = .cancelled
                failure = CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                item.state = .cancelled
                failure = error
            } catch {
                item.state = .failed(StorageErrorText.summary(for: error, kind: item.provider.kind))
                failure = error
            }

            // Fire-once: a retry must not signal a waiting file promise twice.
            let finish = item.onFinish
            item.onFinish = nil
            finish?(failure)

            self?.postChange()
            self?.startEligible()
        }
    }

    private func updateProgress(id: UUID, sent: Int64, total: Int64) {
        guard let item = transfers.first(where: { $0.id == id }), item.state == .running else { return }
        item.bytesTransferred = min(max(sent, 0), total)
        postProgress()
    }

    // MARK: - Notifications

    private func postChange() {
        NotificationCenter.default.post(name: .transferQueueDidChange, object: self)
    }

    /// Coalesce high-frequency byte callbacks into ~12 Hz UI updates.
    private func postProgress() {
        guard !progressPostScheduled else { return }
        progressPostScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.progressPostScheduled = false
            NotificationCenter.default.post(name: .transferQueueProgress, object: self)
        }
    }
}
