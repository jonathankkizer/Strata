import Foundation

/// Full metadata for a single object, richer than what a listing returns. Fetched
/// on demand (an Azure Get Blob Properties / HEAD) when the inspector needs it.
struct ObjectMetadata: Sendable {
    var size: Int64
    var contentType: String?
    var storageClass: String?
    var etag: String?
    var lastModified: Date?
    /// Azure block/append/page blob type; nil for providers without the concept.
    var blobType: String?
    /// Custom user metadata (Azure `x-ms-meta-*`, S3 `x-amz-meta-*`).
    var custom: [String: String]

    init(
        size: Int64 = 0,
        contentType: String? = nil,
        storageClass: String? = nil,
        etag: String? = nil,
        lastModified: Date? = nil,
        blobType: String? = nil,
        custom: [String: String] = [:]
    ) {
        self.size = size
        self.contentType = contentType
        self.storageClass = storageClass
        self.etag = etag
        self.lastModified = lastModified
        self.blobType = blobType
        self.custom = custom
    }
}
