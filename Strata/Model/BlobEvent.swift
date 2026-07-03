import Foundation

/// The Azure Event Grid `data.api` value a blob write emits. Downstream
/// subscriptions (Azure Functions, Logic Apps, ADF/Synapse storage-event
/// triggers) routinely filter on this field, so the REST operation the client
/// chooses determines whether a pipeline actually fires. This is the model
/// behind Strata's differentiating "predict-and-verify the event" feature.
enum BlobWriteAPI: String, Sendable, CaseIterable {
    case putBlob = "PutBlob"
    case putBlockList = "PutBlockList"
    case copyBlob = "CopyBlob"
    case createFile = "CreateFile"
    case flushWithClose = "FlushWithClose"
    case sftpCreate = "SftpCreate"
    case sftpCommit = "SftpCommit"

    /// Whether a standard `BlobCreated` subscription fires on full commit for this
    /// operation. Microsoft documents `CopyBlob`, `PutBlob`, `PutBlockList`, and
    /// `FlushWithClose` as the commit operations; SFTP and the DFS open
    /// (`CreateFile`) do not match the recommended filter set.
    var firesBlobCreatedOnCommit: Bool {
        switch self {
        case .putBlob, .putBlockList, .copyBlob, .flushWithClose:
            return true
        case .createFile, .sftpCreate, .sftpCommit:
            return false
        }
    }
}

/// Which endpoint a write goes through. This choice — not just the byte count —
/// determines the emitted event on hierarchical-namespace accounts.
enum UploadEndpoint: Sendable {
    case blob   // *.blob.core.windows.net — flat Blob REST API
    case dfs    // *.dfs.core.windows.net — ADLS Gen2 native writes
    case sftp   // SFTP endpoint — event-incompatible with standard filters
}

/// A deliberate, inspectable description of how a blob will be written. Every
/// write operation declares the event it will emit, wired into the transfer
/// model from day one.
struct UploadPlan: Sendable, Hashable {
    var byteCount: Int64
    var endpoint: UploadEndpoint
    /// Below this size Strata uses a single-shot `Put Blob`; above it, staged
    /// `Put Block` × N + `Put Block List`. Both emit pipeline-friendly events.
    /// Surfaced in Preferences.
    var singleShotThreshold: Int64

    static let defaultSingleShotThreshold: Int64 = 256 * 1024 * 1024 // 256 MiB

    init(byteCount: Int64, endpoint: UploadEndpoint = .blob, singleShotThreshold: Int64 = UploadPlan.defaultSingleShotThreshold) {
        self.byteCount = byteCount
        self.endpoint = endpoint
        self.singleShotThreshold = singleShotThreshold
    }

    /// The commit-time `data.api` value the downstream pipeline will observe.
    /// Deterministic from the operation the app chooses — needs only data-plane
    /// access, so this prediction always works (ships in v1).
    var predictedCommitAPI: BlobWriteAPI {
        switch endpoint {
        case .sftp:
            return .sftpCommit
        case .dfs:
            return .flushWithClose
        case .blob:
            return byteCount <= singleShotThreshold ? .putBlob : .putBlockList
        }
    }

    /// Human-readable summary for the transfer queue badge / inspector, e.g.
    /// "emits BlobCreated with api: PutBlockList".
    var predictedEventSummary: String {
        let api = predictedCommitAPI
        if api.firesBlobCreatedOnCommit {
            return "emits BlobCreated with api: \(api.rawValue)"
        } else {
            return "emits api: \(api.rawValue) — does NOT match standard BlobCreated filters"
        }
    }
}

extension UploadEndpoint: Equatable, Hashable {}
