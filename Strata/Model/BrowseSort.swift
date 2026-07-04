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
    func areInOrder(_ lhs: StorageObject, _ rhs: StorageObject) -> Bool {
        if lhs.isPrefix != rhs.isPrefix { return lhs.isPrefix }
        let ordered: Bool
        switch key {
        case .name:
            ordered = lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
        case .kind:
            ordered = (lhs.contentType ?? "").localizedStandardCompare(rhs.contentType ?? "") == .orderedAscending
        case .dateModified:
            ordered = (lhs.lastModified ?? .distantPast) < (rhs.lastModified ?? .distantPast)
        case .size:
            ordered = lhs.size < rhs.size
        case .tier:
            ordered = (lhs.storageClass ?? "").localizedStandardCompare(rhs.storageClass ?? "") == .orderedAscending
        }
        return ascending ? ordered : !ordered
    }
}
