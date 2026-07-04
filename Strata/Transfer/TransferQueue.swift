import Foundation

/// App-wide upload queue. Runs transfers with bounded concurrency, reports real
/// byte progress, and supports cancel and retry. Cancellation rides on structured
/// concurrency: each transfer runs in a `Task`, and cancelling it cancels the
/// in-flight URLSession upload. MainActor-isolated; observers subscribe via
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
        let item = TransferItem(
            fileURL: fileURL,
            key: key,
            container: container,
            destination: destination,
            contentType: contentType,
            plan: plan,
            provider: provider
        )
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
            do {
                let data = try await Self.readData(item.sourceURL)
                try await item.provider.upload(
                    data,
                    toKey: item.key,
                    in: item.container,
                    contentType: item.contentType,
                    plan: item.plan,
                    onProgress: { sent, _ in
                        Task { @MainActor in TransferQueue.shared.updateProgress(id: id, sent: sent, total: total) }
                    }
                )
                item.bytesTransferred = item.byteCount
                item.state = .completed
            } catch is CancellationError {
                item.state = .cancelled
            } catch let error as URLError where error.code == .cancelled {
                item.state = .cancelled
            } catch {
                item.state = .failed(Self.describe(error))
            }
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

    // MARK: - Helpers

    /// Read off the main actor so large files don't stall the UI.
    nonisolated private static func readData(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) { try Data(contentsOf: url) }.value
    }

    nonisolated private static func describe(_ error: Error) -> String {
        if case StorageProviderError.dataPlaneForbidden = error {
            return "Forbidden — needs a Storage Blob Data Contributor role."
        }
        return error.localizedDescription
    }
}
