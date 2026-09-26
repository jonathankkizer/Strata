import Foundation

/// What to say when a batch of transfers finishes while Strata is in the background.
///
/// A batch is everything that finished between the queue going busy and going idle
/// again, so dropping forty files gives one notification, not forty. Cancelled
/// transfers aren't mentioned: the user stopped them and already knows. Pure, so the
/// wording is testable.
struct TransferSummary: Equatable {

    struct Outcome: Equatable {
        var direction: TransferDirection
        var fileName: String
        /// Nil when it succeeded.
        var failure: String?
    }

    let title: String
    let body: String

    /// Nil when there's nothing worth saying (an empty batch, or only cancellations
    /// already filtered out by the caller).
    static func make(_ outcomes: [Outcome]) -> TransferSummary? {
        guard !outcomes.isEmpty else { return nil }
        let failed = outcomes.filter { $0.failure != nil }
        let succeeded = outcomes.filter { $0.failure == nil }

        if failed.isEmpty {
            if succeeded.count == 1, let only = succeeded.first {
                return TransferSummary(
                    title: only.direction == .upload ? "Upload finished" : "Download finished",
                    body: only.fileName
                )
            }
            return TransferSummary(title: "\(succeeded.count) \(noun(for: succeeded)) finished", body: names(succeeded))
        }

        if failed.count == 1, let only = failed.first {
            let verb = only.direction == .upload ? "upload" : "download"
            let title = succeeded.isEmpty
                ? "Couldn\u{2019}t \(verb) \u{201C}\(only.fileName)\u{201D}"
                : "\(succeeded.count) finished, 1 failed"
            let body = succeeded.isEmpty
                ? (only.failure ?? "")
                : "\u{201C}\(only.fileName)\u{201D}: \(only.failure ?? "")"
            return TransferSummary(title: title, body: body)
        }

        let title = succeeded.isEmpty
            ? "\(failed.count) \(noun(for: failed)) failed"
            : "\(succeeded.count) finished, \(failed.count) failed"
        return TransferSummary(title: title, body: "Failed: " + names(failed))
    }

    /// "uploads", "downloads", or "transfers" when it's a mix.
    private static func noun(for outcomes: [Outcome]) -> String {
        let directions = Set(outcomes.map { $0.direction == .upload })
        guard directions.count == 1, let isUpload = directions.first else { return "transfers" }
        return isUpload ? "uploads" : "downloads"
    }

    /// Up to two names, then a count: "a.csv, b.csv and 3 more".
    private static func names(_ outcomes: [Outcome]) -> String {
        let shown = outcomes.prefix(2).map(\.fileName)
        let rest = outcomes.count - shown.count
        let list = shown.joined(separator: ", ")
        return rest > 0 ? "\(list) and \(rest) more" : list
    }
}
