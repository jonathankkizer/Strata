import Foundation

/// Everything a delete is about to remove, and how to say it.
///
/// A folder in object storage is only a prefix, so deleting one means deleting every key
/// under it. The count therefore cannot be known from the selection alone — it has to be
/// listed first — and a confirmation that doesn't say how many objects are really about
/// to go is not a confirmation. Pure policy and wording, no AppKit and no network, so
/// the arithmetic and the phrasing are both testable.
struct DeletionPlan: Sendable, Equatable {

    /// The keys that will actually be deleted, deepest first.
    let keys: [String]
    /// What the user selected, before any folder was expanded.
    let selectedObjectCount: Int
    let selectedFolderCount: Int
    /// The name of the one thing selected, when exactly one thing was.
    let singleName: String?
    let totalBytes: Int64

    var isEmpty: Bool { keys.isEmpty }
    var hasFolders: Bool { selectedFolderCount > 0 }

    /// Deleting a folder removes objects the user never picked one by one, so the count
    /// is worth calling out even when only one thing was selected.
    var expandedBeyondSelection: Bool {
        keys.count > selectedObjectCount + selectedFolderCount
    }

    /// The keys grouped by how deep they are, deepest first.
    ///
    /// Everything within one batch is independent and can go at once; the batches
    /// themselves must go in order. A hierarchical-namespace account has real
    /// directories that refuse to be deleted while anything is still inside them, so a
    /// parent must never be in flight alongside its own children — which is exactly what
    /// a flat list chunked by a concurrency limit would allow at the chunk boundary.
    var batches: [[String]] {
        var byDepth: [Int: [String]] = [:]
        for key in keys { byDepth[Self.depth(key), default: []].append(key) }
        return byDepth.keys.sorted(by: >).map { byDepth[$0]! }
    }

    /// The sheet's question. Named things are named; anything else is counted.
    var title: String {
        if let singleName {
            return "Delete \u{201C}\(singleName)\u{201D}?"
        }
        let total = selectedObjectCount + selectedFolderCount
        return "Delete \(total) items?"
    }

    /// The line beneath it: what that actually amounts to, and how big.
    var detail: String {
        var parts: [String] = []
        if keys.isEmpty {
            return "There is nothing inside to delete."
        }
        parts.append("\(keys.count) \(keys.count == 1 ? "object" : "objects")")
        if totalBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
        }
        return parts.joined(separator: " \u{2022} ")
    }

    /// Builds a plan from a selection and the keys a folder expansion turned up.
    ///
    /// Keys are ordered deepest first. Azure hierarchical-namespace accounts have real
    /// directories that refuse to be deleted while anything is inside them, and a flat
    /// account can hold a zero-byte marker blob at the folder's own key — both come out
    /// right if children go before their parents.
    static func make(
        selection: [StorageObject],
        expandedKeys: [String: [StorageObject]] = [:]
    ) -> DeletionPlan {
        var keys: [String] = []
        var bytes: Int64 = 0
        var objectCount = 0
        var folderCount = 0

        for item in selection {
            if item.isPrefix {
                folderCount += 1
                for child in expandedKeys[item.key] ?? [] {
                    keys.append(child.key)
                    bytes += child.size
                }
                // The prefix itself may exist as a real object — a directory on a
                // hierarchical account, or a zero-byte marker on a flat one. Deleting a
                // key that was never there succeeds on both clouds, so asking for it
                // costs nothing and missing it would leave an empty folder behind.
                keys.append(item.key)
            } else {
                objectCount += 1
                keys.append(item.key)
                bytes += item.size
            }
        }

        // Deepest first, and de-duplicated: two selected folders can nest, and a key
        // asked for twice would report a phantom second deletion.
        var seen = Set<String>()
        let ordered = keys
            .filter { seen.insert($0).inserted }
            .sorted { depth($0) > depth($1) }

        return DeletionPlan(
            keys: ordered,
            selectedObjectCount: objectCount,
            selectedFolderCount: folderCount,
            singleName: selection.count == 1 ? displayName(for: selection[0]) : nil,
            totalBytes: bytes
        )
    }

    /// How many levels down a key sits.
    ///
    /// A folder's own key carries a trailing slash, so counting separators naively puts
    /// `logs/` at the same depth as `logs/a.log` — which would let a directory be
    /// deleted alongside its own contents, exactly the race the batching exists to
    /// prevent. The trailing slash names the folder; it does not descend into it.
    private static func depth(_ key: String) -> Int {
        var key = key
        if key.hasSuffix("/") { key.removeLast() }
        return key.reduce(0) { $1 == "/" ? $0 + 1 : $0 }
    }

    /// The last path component, which is what the row showed.
    private static func displayName(for object: StorageObject) -> String {
        var key = object.key
        if key.hasSuffix("/") { key.removeLast() }
        return key.split(separator: "/").last.map(String.init) ?? key
    }
}

/// One key that could not be deleted. Collected rather than thrown, because stopping at
/// the first failure in the middle of a folder leaves the user with no idea what did and
/// didn't go.
struct DeletionFailure: Sendable, Equatable {
    let key: String
    let message: String
}
