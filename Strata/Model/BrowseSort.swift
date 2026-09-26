import Foundation

/// A sort field for the browser. Raw values match the list view's column
/// identifiers so NSTableView sort descriptors map directly. "Kind" is the object's
/// content type; "Tier" is the Azure access tier.
enum SortKey: String, CaseIterable, Sendable {
    case name
    case kind
    case dateModified = "modified"
    case size
    case tier

    var displayName: String {
        switch self {
        case .name: return "Name"
        case .kind: return "Kind"
        case .dateModified: return "Date Modified"
        case .size: return "Size"
        case .tier: return "Tier"
        }
    }
}

/// The current sort field and direction.
struct BrowseSort: Equatable, Sendable {
    var key: SortKey = .name
    var ascending: Bool = true

    /// Orders two objects for this sort, with folders always kept before blobs.
    ///
    /// A strict ordering, as `sort(by:)` requires: two items that tie on the sort field
    /// are never "in order" both ways round. Negating the ascending answer for a
    /// descending sort broke that (it said yes for equal items), which scrambled rows
    /// of equal size or date. Ties fall back to the name, then the raw key, so equal
    /// rows also keep a stable, Finder-like order.
    func areInOrder(_ lhs: StorageObject, _ rhs: StorageObject) -> Bool {
        if lhs.isPrefix != rhs.isPrefix { return lhs.isPrefix }
        let primary = compare(lhs, rhs)
        if primary != .orderedSame {
            return ascending ? primary == .orderedAscending : primary == .orderedDescending
        }
        let byName = lhs.key.localizedStandardCompare(rhs.key)
        if byName != .orderedSame { return byName == .orderedAscending }
        return lhs.key < rhs.key
    }

    private func compare(_ lhs: StorageObject, _ rhs: StorageObject) -> ComparisonResult {
        switch key {
        case .name:
            return lhs.key.localizedStandardCompare(rhs.key)
        case .kind:
            return (lhs.contentType ?? "").localizedStandardCompare(rhs.contentType ?? "")
        case .dateModified:
            return Self.compare(lhs.lastModified ?? .distantPast, rhs.lastModified ?? .distantPast)
        case .size:
            return Self.compare(lhs.size, rhs.size)
        case .tier:
            return (lhs.storageClass ?? "").localizedStandardCompare(rhs.storageClass ?? "")
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
    }

    /// Merges a newly arrived, unsorted page into rows already in this order. Sorting
    /// the page and merging is linear in the rows held, where re-sorting everything on
    /// each of a hundred pages would not be.
    func merging(_ page: [StorageObject], into sorted: [StorageObject]) -> [StorageObject] {
        let incoming = page.sorted(by: areInOrder)
        var merged: [StorageObject] = []
        merged.reserveCapacity(sorted.count + incoming.count)
        var i = sorted.startIndex, j = incoming.startIndex
        while i < sorted.endIndex, j < incoming.endIndex {
            if areInOrder(incoming[j], sorted[i]) {
                merged.append(incoming[j]); j += 1
            } else {
                merged.append(sorted[i]); i += 1
            }
        }
        merged.append(contentsOf: sorted[i...])
        merged.append(contentsOf: incoming[j...])
        return merged
    }
}
