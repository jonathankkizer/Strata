import Foundation

/// A single stored object: an S3 object or an Azure blob. Generic concepts
/// (storage tier, content-type, metadata) are modeled abstractly; provider-only
/// details live in provider-specific inspector panes.
struct StorageObject: Sendable, Identifiable, Hashable {
    var id: String { key }
    var key: String
    var size: Int64
    var lastModified: Date?
    /// S3 storage class or Azure access tier (Hot/Cool/Cold/Archive).
    var storageClass: String?
    var contentType: String?
    var etag: String?
    var metadata: [String: String]
    /// A common prefix ("folder") rather than a real object.
    var isPrefix: Bool

    init(
        key: String,
        size: Int64 = 0,
        lastModified: Date? = nil,
        storageClass: String? = nil,
        contentType: String? = nil,
        etag: String? = nil,
        metadata: [String: String] = [:],
        isPrefix: Bool = false
    ) {
        self.key = key
        self.size = size
        self.lastModified = lastModified
        self.storageClass = storageClass
        self.contentType = contentType
        self.etag = etag
        self.metadata = metadata
        self.isPrefix = isPrefix
    }
}
