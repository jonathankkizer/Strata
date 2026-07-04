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

    /// Writes `data` to `key`. The `plan` declares which REST operation is used —
    /// and therefore which storage event fires — so callers can predict and surface
    /// it before the upload happens.
    func upload(_ data: Data, toKey key: String, in container: StorageContainer, contentType: String?, plan: UploadPlan) async throws
}

enum StorageProviderError: Error, Sendable {
    case notImplemented
    /// Azure: a valid Entra token, but the identity lacks a `Storage Blob Data *`
    /// role. Management-plane roles (Owner/Contributor/Reader) do NOT grant data
    /// access — this is surfaced with a specific message, not a generic auth error.
    case dataPlaneForbidden(account: String)
    case unauthorized
}
