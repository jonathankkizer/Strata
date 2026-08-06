import Foundation

/// What actually happens to an object after Strata deletes it.
///
/// Object storage has no Trash, so the honest answer depends on the container: with
/// Azure soft delete or S3 versioning turned on a delete is reversible for a while, and
/// without them it is over the moment it lands. Telling the user which one they are in
/// *before* they commit is the same idea as predicting the write event an upload will
/// emit — say what the cloud is really going to do, rather than a generic warning that
/// is wrong half the time.
enum DeletionRecovery: Sendable, Equatable {

    /// Nothing is kept. The object is gone.
    case permanent

    /// Azure soft delete: the blob is retained and restorable for this many days.
    case retained(days: Int)

    /// Versioning: the delete leaves a marker and the previous version stays put.
    case versioned

    /// Both, which is a common Azure configuration.
    case versionedAndRetained(days: Int)

    /// The account would not say. Reading the policy needs a permission the user may
    /// not have, and guessing "recoverable" would be the dangerous way to be wrong.
    case unknown

    var isRecoverable: Bool {
        switch self {
        case .permanent, .unknown: return false
        case .retained, .versioned, .versionedAndRetained: return true
        }
    }

    /// The line shown under the confirmation's question.
    var summary: String {
        switch self {
        case .permanent:
            return "This can\u{2019}t be undone."
        case .retained(let days):
            return "Soft delete is on: recoverable for \(days) \(days == 1 ? "day" : "days")."
        case .versioned:
            return "Versioning is on: the previous version is kept."
        case .versionedAndRetained(let days):
            return "Versioning and soft delete are on: recoverable for \(days) \(days == 1 ? "day" : "days")."
        case .unknown:
            return "Strata couldn\u{2019}t read this account\u{2019}s retention policy. Assume this can\u{2019}t be undone."
        }
    }

    /// Builds the case from what the two clouds each report. Azure answers both parts;
    /// S3 has versioning only, and passes `retentionDays: nil`.
    static func from(versioningEnabled: Bool, retentionDays: Int?) -> DeletionRecovery {
        // A retention policy that is enabled but set to zero days retains nothing, so it
        // is not something to reassure anyone with.
        let days = retentionDays.flatMap { $0 > 0 ? $0 : nil }
        switch (versioningEnabled, days) {
        case (true, let days?): return .versionedAndRetained(days: days)
        case (true, nil): return .versioned
        case (false, let days?): return .retained(days: days)
        case (false, nil): return .permanent
        }
    }
}
