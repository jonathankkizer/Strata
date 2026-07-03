import Foundation

/// Compares an upload's predicted `data.api` against an Event Grid subscription's
/// filter. Deterministic prediction (v1) needs only the `UploadPlan`; subscription
/// matching (v2) needs management RBAC to read the actual filters and degrades
/// gracefully when that access is absent.
enum EventPredictionService {

    /// v1: deterministic prediction — always available with data-plane access.
    static func predictedEvent(for plan: UploadPlan) -> BlobWriteAPI {
        plan.predictedCommitAPI
    }

    enum FilterMatch: Sendable, Equatable {
        /// The emitted api is in the subscription's `data.api StringIn (...)` set.
        case willFire
        /// The emitted api is not in the filter set — the subscriber won't fire.
        case willNotFire(emitted: BlobWriteAPI, filter: [String])
        /// No management access to read filters; deterministic prediction only.
        case unknownNoManagementAccess
    }

    /// v2: subscription matching — lights up when `EventGrid/eventSubscriptions/read`
    /// is granted on the storage account's system topic.
    static func match(plan: UploadPlan, againstFilter apiFilter: [String]?) -> FilterMatch {
        guard let apiFilter else { return .unknownNoManagementAccess }
        let emitted = plan.predictedCommitAPI
        return apiFilter.contains(emitted.rawValue)
            ? .willFire
            : .willNotFire(emitted: emitted, filter: apiFilter)
    }
}
