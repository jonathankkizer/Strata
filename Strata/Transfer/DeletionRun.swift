import Foundation

/// Executes a `DeletionPlan` against a provider.
///
/// Deletes go one key at a time with bounded concurrency rather than through a batch
/// API. S3's `DeleteObjects` would collapse a thousand keys into one request, but Azure
/// has no equivalent worth the complexity, and per-key requests buy two things that
/// matter more here than round trips: honest progress, and knowing exactly which keys
/// failed when some of them do.
struct DeletionRun: Sendable {

    let provider: any StorageProvider
    let container: StorageContainer
    let plan: DeletionPlan

    /// Enough to keep the connection busy without burying a rate-limited account.
    static let concurrency = 8

    /// Deletes every key in the plan, reporting the number finished as it goes.
    ///
    /// Failures are collected, not thrown: stopping at the first one in the middle of a
    /// folder would leave the user with no idea what did and didn't go. Cancellation is
    /// honoured between keys, so a Stop button takes effect without abandoning a request
    /// mid-flight.
    func run(onProgress: @Sendable @escaping (Int) -> Void) async -> [DeletionFailure] {
        var failures: [DeletionFailure] = []
        var finished = 0

        // Depth batch by depth batch, deepest first, so a hierarchical account's
        // directories are emptied before they are removed. Concurrency is bounded
        // *within* a batch — a parent is never in flight alongside its own children.
        for chunk in plan.batches.flatMap({ $0.chunked(into: Self.concurrency) }) {
            if Task.isCancelled { break }

            let chunkFailures = await withTaskGroup(of: DeletionFailure?.self) { group in
                for key in chunk {
                    group.addTask {
                        do {
                            try await provider.delete(key: key, in: container)
                            return nil
                        } catch {
                            return DeletionFailure(key: key, message: error.localizedDescription)
                        }
                    }
                }
                var collected: [DeletionFailure] = []
                for await failure in group {
                    if let failure { collected.append(failure) }
                }
                return collected
            }

            failures.append(contentsOf: chunkFailures)
            finished += chunk.count
            onProgress(finished)
        }

        return failures
    }
}

extension Array {
    /// Fixed-size slices, in order. Used to bound how many deletes are in flight while
    /// keeping the deepest-first ordering the plan established.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
