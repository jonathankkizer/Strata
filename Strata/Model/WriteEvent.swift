import Foundation

/// What a write will look like to whatever is subscribed to the bucket or container —
/// stated in the provider's own vocabulary, but in a shape the UI can render without
/// knowing which cloud it is looking at.
///
/// This is the generalisation of Strata's differentiator. The insight isn't
/// Azure-specific: on both clouds, the REST operation the client picks decides which
/// event name downstream sees, and a subscription filtered to the wrong one silently
/// never fires. Only the names differ.
struct PredictedWriteEvent: Sendable, Hashable {

    /// Whether default/wildcard subscriptions pick this write up, and what to say
    /// about it. Drives the inspector's green check versus orange warning.
    enum Confidence: Sendable, Hashable {
        /// Standard subscriptions fire on this write.
        case fires(String)
        /// They may not — with the reason, because "may not" alone is useless.
        case warns(String)

        var isReassuring: Bool {
            if case .fires = self { return true }
            return false
        }

        var message: String {
            switch self {
            case .fires(let text), .warns(let text): return text
            }
        }
    }

    /// The provider's name for the emitted event, shown as the transfer badge:
    /// `PutBlockList`, `s3:ObjectCreated:CompleteMultipartUpload`.
    var eventName: String
    /// What the provider calls its notification system — the inspector section title.
    var systemName: String
    /// The operation in human terms: "Put Blob (single-shot)".
    var operationSummary: String
    /// What downstream will see, for the inspector's "Emits" row. Compact, because
    /// that row lives in a narrow pane.
    var emissionSummary: String
    /// The same fact as prose, for the upload confirmation sheet, which lists one line
    /// per file and reads as sentences. Deliberately a separate string rather than
    /// derived from `emissionSummary`: the two are read in different places at
    /// different widths, and collapsing them made the sheet worse.
    var summary: String
    var confidence: Confidence
}
