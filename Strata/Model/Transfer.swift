import Foundation

/// A unit of work in the transfer queue. The engine will handle same-provider
/// copy (server-side where possible), cross-provider copy (stream through local),
/// and upload/download. Writes carry an `UploadPlan` so the queue can show which
/// storage event each transfer will emit.
struct Transfer: Sendable, Identifiable {
    let id: UUID
    var sourceDescription: String
    var destinationDescription: String
    var byteCount: Int64
    var state: TransferState
    /// Present for write operations; declares the emitted Event Grid event.
    var uploadPlan: UploadPlan?

    init(
        id: UUID = UUID(),
        sourceDescription: String,
        destinationDescription: String,
        byteCount: Int64,
        state: TransferState = .queued,
        uploadPlan: UploadPlan? = nil
    ) {
        self.id = id
        self.sourceDescription = sourceDescription
        self.destinationDescription = destinationDescription
        self.byteCount = byteCount
        self.state = state
        self.uploadPlan = uploadPlan
    }
}

enum TransferState: Sendable, Equatable {
    case queued
    case running(fractionCompleted: Double)
    case paused
    case completed
    case failed(reason: String)
}
