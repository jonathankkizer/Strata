import Foundation

enum TransferState: Sendable, Equatable {
    case queued
    case running
    case completed
    case cancelled
    case failed(String)
}

/// Which way the bytes move. Uploads carry an `UploadPlan` (and therefore a
/// predicted storage event); downloads do not, because reads emit no event.
enum TransferDirection: Sendable, Equatable {
    case upload
    case download
}

extension Notification.Name {
    /// Structural changes: a transfer was added, started, finished, or cleared.
    static let transferQueueDidChange = Notification.Name("StrataTransferQueueDidChange")
    /// Frequent, coalesced byte-progress ticks.
    static let transferQueueProgress = Notification.Name("StrataTransferQueueProgress")
    /// Posted when new transfers are enqueued, so the UI can reveal the queue.
    static let transferQueueDidEnqueue = Notification.Name("StrataTransferQueueDidEnqueue")
}

/// One transfer in the queue — an upload or a download. A reference type so progress
/// updates mutate in place and the table reflects them without rebuilding the model.
/// MainActor-isolated — it is only ever touched from the UI/queue on the main actor.
@MainActor
final class TransferItem {
    let id = UUID()
    let direction: TransferDirection
    /// Display name: the file name at whichever end is local.
    let fileName: String
    /// Human-readable "where it's going": the remote folder for an upload, the local
    /// folder for a download.
    let destination: String
    let key: String
    let container: StorageContainer
    /// The local end of the transfer — the source file for an upload, the destination
    /// file for a download.
    let localURL: URL
    let contentType: String?
    /// Uploads only: the plan whose predicted REST operation drives the write.
    let plan: UploadPlan?
    let provider: any StorageProvider
    /// Expected size. For a download this comes from the listing, which is
    /// authoritative enough for progress even when the service omits Content-Length.
    let byteCount: Int64
    /// Uploads only: the Event Grid `data.api` this transfer will emit — a row badge.
    let predictedAPI: BlobWriteAPI?

    /// Called once when the transfer reaches a terminal state. Used by the
    /// drag-to-Finder file promise, which must not signal Finder until the bytes
    /// have actually landed.
    var onFinish: ((Error?) -> Void)?

    var bytesTransferred: Int64 = 0
    var state: TransferState = .queued
    var task: Task<Void, Never>?

    /// An upload: `fileURL` on disk → `key` in `container`.
    init(
        uploadFrom fileURL: URL,
        key: String,
        container: StorageContainer,
        destination: String,
        contentType: String?,
        plan: UploadPlan,
        provider: any StorageProvider
    ) {
        self.direction = .upload
        self.localURL = fileURL
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

    /// A download: `key` in `container` → `destinationURL` on disk.
    init(
        downloadKey key: String,
        container: StorageContainer,
        to destinationURL: URL,
        byteCount: Int64,
        contentType: String?,
        provider: any StorageProvider
    ) {
        self.direction = .download
        self.localURL = destinationURL
        self.fileName = destinationURL.lastPathComponent
        self.key = key
        self.container = container
        self.destination = (destinationURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        self.contentType = contentType
        self.plan = nil
        self.provider = provider
        self.byteCount = byteCount
        self.predictedAPI = nil
    }

    var fractionCompleted: Double {
        if state == .completed { return 1 }
        guard byteCount > 0 else { return 0 }
        return min(1, Double(bytesTransferred) / Double(byteCount))
    }

    var isActive: Bool { state == .queued || state == .running }

    var isRetryable: Bool {
        if case .failed = state { return true }
        return state == .cancelled
    }

    /// True once a completed download's file is on disk and can be revealed.
    var canRevealInFinder: Bool {
        direction == .download && state == .completed
    }
}
