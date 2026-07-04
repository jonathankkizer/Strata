import Foundation

enum TransferState: Sendable, Equatable {
    case queued
    case running
    case completed
    case cancelled
    case failed(String)
}

extension Notification.Name {
    /// Structural changes: a transfer was added, started, finished, or cleared.
    static let transferQueueDidChange = Notification.Name("StrataTransferQueueDidChange")
    /// Frequent, coalesced byte-progress ticks.
    static let transferQueueProgress = Notification.Name("StrataTransferQueueProgress")
    /// Posted when new transfers are enqueued, so the UI can reveal the queue.
    static let transferQueueDidEnqueue = Notification.Name("StrataTransferQueueDidEnqueue")
}

/// One upload in the queue. A reference type so progress updates mutate in place
/// and the table reflects them without rebuilding the model. MainActor-isolated —
/// it is only ever touched from the UI/queue on the main actor.
@MainActor
final class TransferItem {
    let id = UUID()
    let fileName: String
    let destination: String
    let key: String
    let container: StorageContainer
    let sourceURL: URL
    let contentType: String?
    let plan: UploadPlan
    let provider: any StorageProvider
    let byteCount: Int64
    /// The Event Grid `data.api` this transfer will emit — shown as a row badge.
    let predictedAPI: BlobWriteAPI

    var bytesTransferred: Int64 = 0
    var state: TransferState = .queued
    var task: Task<Void, Never>?

    init(
        fileURL: URL,
        key: String,
        container: StorageContainer,
        destination: String,
        contentType: String?,
        plan: UploadPlan,
        provider: any StorageProvider
    ) {
        self.sourceURL = fileURL
        self.fileName = fileURL.lastPathComponent
        self.key = key
        self.container = container
        self.destination = destination
        self.contentType = contentType
        self.plan = plan
        self.provider = provider
        self.byteCount = plan.byteCount
        self.predictedAPI = plan.predictedCommitAPI
    }

    var fractionCompleted: Double {
        if state == .completed { return 1 }
        guard byteCount > 0 else { return state == .running ? 0 : 0 }
        return min(1, Double(bytesTransferred) / Double(byteCount))
    }

    var isActive: Bool { state == .queued || state == .running }

    var isRetryable: Bool {
        if case .failed = state { return true }
        return state == .cancelled
    }
}
