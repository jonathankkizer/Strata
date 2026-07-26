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

/// The S3 analog of `BlobWriteAPI`: which `s3:ObjectCreated:*` event a write emits.
///
/// The same footgun exists here as on Azure, in different clothing. A single-request
/// `PutObject` emits `s3:ObjectCreated:Put`; a multipart upload emits
/// `s3:ObjectCreated:CompleteMultipartUpload`. A notification configured for the
/// wildcard catches both — but one narrowed to `:Put` silently never fires for
/// anything large enough to go multipart, which is exactly the class of invisible
/// pipeline failure Strata exists to surface.
enum S3WriteOperation: String, Sendable, CaseIterable {
    case put = "s3:ObjectCreated:Put"
    case completeMultipartUpload = "s3:ObjectCreated:CompleteMultipartUpload"

    /// True when a notification filtered to `s3:ObjectCreated:Put` — a common way to
    /// write it — would miss this write.
    var missedByPutOnlyFilter: Bool { self == .completeMultipartUpload }
}

/// Which cloud (and, on Azure, which endpoint) a write is going to. Determines the
/// operation, and therefore the event.
enum UploadTarget: Sendable, Hashable {
    case azureBlob(endpoint: UploadEndpoint)
    case s3

    /// What to assume for a provider absent a more specific choice. Azure defaults to
    /// the flat blob endpoint, which is what the app writes through today.
    static func `default`(for kind: ProviderKind) -> UploadTarget {
        switch kind {
        case .azureBlob: return .azureBlob(endpoint: .blob)
        case .s3: return .s3
        }
    }
}

/// A deliberate, inspectable description of how an object will be written. Every
/// write operation declares the event it will emit, wired into the transfer
/// model from day one.
struct UploadPlan: Sendable, Hashable {
    var byteCount: Int64
    var target: UploadTarget
    /// Below this size a single request is used; above it, a staged/multipart write.
    /// Azure: `Put Blob` vs `Put Block` × N + `Put Block List`. S3: `PutObject` vs
    /// `CreateMultipartUpload`/`UploadPart`/`CompleteMultipartUpload`.
    var singleShotThreshold: Int64

    /// Azure's `Put Blob` accepts up to 5000 MiB; this is well under it and keeps
    /// single-shot memory/retry behaviour sane.
    static let defaultSingleShotThreshold: Int64 = 256 * 1024 * 1024 // 256 MiB
    /// S3's single-request `PutObject` ceiling is 5 GiB, but the useful threshold is
    /// far lower — the AWS CLI switches to multipart at 8 MiB. Matching a familiar
    /// default matters here, because it decides which event fires.
    static let defaultS3MultipartThreshold: Int64 = 8 * 1024 * 1024 // 8 MiB

    init(byteCount: Int64, target: UploadTarget, singleShotThreshold: Int64? = nil) {
        self.byteCount = byteCount
        self.target = target
        self.singleShotThreshold = singleShotThreshold ?? Self.defaultThreshold(for: target)
    }

    static func defaultThreshold(for target: UploadTarget) -> Int64 {
        switch target {
        case .azureBlob: return defaultSingleShotThreshold
        case .s3: return defaultS3MultipartThreshold
        }
    }

    /// Whether the write is staged across multiple requests rather than sent in one.
    /// Provider-neutral, and on both clouds it's what decides the event.
    var usesMultipleRequests: Bool {
        switch target {
        case .azureBlob(let endpoint):
            return endpoint == .blob && byteCount > singleShotThreshold
        case .s3:
            return byteCount > singleShotThreshold
        }
    }

    /// The commit-time Azure `data.api`, or nil when this isn't an Azure write. The
    /// Azure provider switches on this to pick its REST path.
    var azureCommitAPI: BlobWriteAPI? {
        guard case .azureBlob(let endpoint) = target else { return nil }
        switch endpoint {
        case .sftp: return .sftpCommit
        case .dfs: return .flushWithClose
        case .blob: return byteCount <= singleShotThreshold ? .putBlob : .putBlockList
        }
    }

    /// The emitted S3 event, or nil when this isn't an S3 write.
    var s3Operation: S3WriteOperation? {
        guard case .s3 = target else { return nil }
        return usesMultipleRequests ? .completeMultipartUpload : .put
    }

    /// The prediction the UI shows, in whichever provider's vocabulary applies.
    var predictedEvent: PredictedWriteEvent {
        switch target {
        case .azureBlob:
            let api = azureCommitAPI ?? .putBlob
            return PredictedWriteEvent(
                eventName: api.rawValue,
                systemName: "Event Grid",
                operationSummary: Self.azureOperationSummary(for: api),
                emissionSummary: api.firesBlobCreatedOnCommit
                    ? "BlobCreated · api: \(api.rawValue)"
                    : "api: \(api.rawValue)",
                summary: api.firesBlobCreatedOnCommit
                    ? "emits BlobCreated with api: \(api.rawValue)"
                    : "emits api: \(api.rawValue) — does NOT match standard BlobCreated filters",
                confidence: api.firesBlobCreatedOnCommit
                    ? .fires("Fires standard BlobCreated subscriptions.")
                    : .warns("Won't match standard BlobCreated filters.")
            )
        case .s3:
            let operation = s3Operation ?? .put
            return PredictedWriteEvent(
                eventName: operation.rawValue,
                systemName: "Event Notifications",
                operationSummary: operation == .put
                    ? "PutObject (single request)"
                    : "Multipart upload (staged)",
                emissionSummary: operation.rawValue,
                summary: operation.missedByPutOnlyFilter
                    ? "emits \(operation.rawValue) — a notification filtered to s3:ObjectCreated:Put will NOT fire"
                    : "emits \(operation.rawValue)",
                confidence: operation.missedByPutOnlyFilter
                    ? .warns("A notification filtered to s3:ObjectCreated:Put won't fire — this commits as CompleteMultipartUpload.")
                    : .fires("Fires s3:ObjectCreated:* and s3:ObjectCreated:Put subscriptions.")
            )
        }
    }

    private static func azureOperationSummary(for api: BlobWriteAPI) -> String {
        switch api {
        case .putBlob: return "Put Blob (single-shot)"
        case .putBlockList: return "Put Block List (staged)"
        case .flushWithClose: return "Flush With Close (DFS)"
        case .sftpCommit, .sftpCreate: return "SFTP write"
        case .copyBlob: return "Copy Blob"
        case .createFile: return "Create File (DFS open)"
        }
    }

    /// One-line form for the upload confirmation sheet.
    var predictedEventSummary: String { predictedEvent.summary }
}

extension UploadEndpoint: Equatable, Hashable {}
