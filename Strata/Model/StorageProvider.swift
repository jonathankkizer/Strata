import Foundation

/// Which cloud a provider talks to. New cases (GCS, S3-compatible) slot in here.
enum ProviderKind: String, Sendable, CaseIterable {
    case s3 = "Amazon S3"
    case azureBlob = "Azure Blob Storage"
}

/// Provider-agnostic core interface. Concrete providers (S3 over the AWS SDK for
/// Swift, Azure over a hand-rolled REST client) conform. Modeled for two providers
/// from day one so S3-only assumptions never leak into the core.
protocol StorageProvider: Sendable {
    var kind: ProviderKind { get }
    var displayName: String { get }

    func listContainers() async throws -> [StorageContainer]
    func listObjects(in container: StorageContainer, prefix: String) async throws -> [StorageObject]

    /// Full metadata for a single object (a HEAD / Get Blob Properties).
    func fetchMetadata(for object: StorageObject, in container: StorageContainer) async throws -> ObjectMetadata

    /// A stable, shareable URL for an object: the https blob URL (Azure) or the
    /// `s3://` URI (S3). Used for "Copy URL" and the pasteboard's URL
    /// representation. Nil when the provider can't yet form one.
    func objectURL(forKey key: String, in container: StorageContainer) -> URL?

    /// Streams `fileURL` to `key`. The `plan` declares which REST operation is used —
    /// and therefore which storage event fires — so callers can predict and surface
    /// it before the upload happens. `onProgress` reports cumulative bytes sent and
    /// the total; it may be called from a background queue.
    func upload(from fileURL: URL, toKey key: String, in container: StorageContainer, contentType: String?, plan: UploadPlan, onProgress: (@Sendable (Int64, Int64) -> Void)?) async throws

    /// Streams `key` to `destinationURL`, replacing anything already there. Memory
    /// stays bounded regardless of blob size — the bytes go to disk, never through a
    /// `Data` in RAM. `onProgress` reports cumulative bytes received and the expected
    /// total (which is `NSURLSessionTransferSizeUnknown` / -1 if the service omits a
    /// length); it may be called from a background queue.
    ///
    /// Reads emit no storage event, so there is no `plan` analog here.
    func download(fromKey key: String, in container: StorageContainer, to destinationURL: URL, onProgress: (@Sendable (Int64, Int64) -> Void)?) async throws
}

enum StorageProviderError: Error, Sendable {
    case notImplemented
    /// Azure: a valid Entra token, but the identity lacks a `Storage Blob Data *`
    /// role. Management-plane roles (Owner/Contributor/Reader) do NOT grant data
    /// access — this is surfaced with a specific message, not a generic auth error.
    case dataPlaneForbidden(account: String)
    case unauthorized
}
