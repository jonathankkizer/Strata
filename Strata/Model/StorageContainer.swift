import Foundation

/// A bucket (S3) or container (Azure). Region/location and provider-specific
/// config surface in an inspector rather than being forced into a false abstraction.
struct StorageContainer: Sendable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var location: String?

    /// ADLS Gen2 hierarchical namespace. Changes which Event Grid event an upload
    /// emits (DFS `FlushWithClose` vs flat blob `PutBlockList`), so it is a
    /// first-class property, surfaced in the account inspector.
    var isHierarchicalNamespace: Bool

    init(name: String, location: String? = nil, isHierarchicalNamespace: Bool = false) {
        self.name = name
        self.location = location
        self.isHierarchicalNamespace = isHierarchicalNamespace
    }
}
