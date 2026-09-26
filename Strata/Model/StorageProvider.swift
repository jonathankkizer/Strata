import Foundation

/// Which cloud a provider talks to. New cases (GCS, S3-compatible) slot in here.
///
/// Raw values are stable slugs, not display strings: they are persisted (in favorites
/// and the last-connected account), so renaming a product must never invalidate
/// somebody's saved places. `displayName` is the user-facing text.
enum ProviderKind: String, Sendable, CaseIterable, Codable {
    case s3
    case azureBlob

    var displayName: String {
        switch self {
        case .s3: return "Amazon S3"
        case .azureBlob: return "Azure Blob Storage"
        }
    }

    /// What this provider calls the thing that holds objects. Used wherever the UI
    /// would otherwise have to say "container" at an S3 user or "bucket" at an Azure
    /// one.
    var containerNoun: String {
        switch self {
        case .s3: return "bucket"
        case .azureBlob: return "container"
        }
    }
}

/// Provider-agnostic core interface. Concrete providers (S3 over the AWS SDK for
/// Swift, Azure over a hand-rolled REST client) conform. Modeled for two providers
/// from day one so S3-only assumptions never leak into the core.
protocol StorageProvider: Sendable {
    var kind: ProviderKind { get }
    var displayName: String { get }

    func listContainers() async throws -> [StorageContainer]
    func listObjects(in container: StorageContainer, prefix: String) async throws -> [StorageObject]
    /// The same listing, handed over page by page. A requirement rather than only an
    /// extension method, so a provider's own paging is what runs when called through
    /// `any StorageProvider` — an extension-only method would always dispatch to the
    /// one-page default.
    func listObjects(
        in container: StorageContainer,
        prefix: String,
        onPage: @escaping @Sendable ([StorageObject]) async -> Void
    ) async throws

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

    /// Removes one object. Both clouds treat deleting a key that isn't there as success,
    /// so this is idempotent — which is what makes a partially-failed folder delete safe
    /// to retry.
    func delete(key: String, in container: StorageContainer) async throws

    /// Every real key under `prefix`, with no folder collapsing. A folder is only a
    /// prefix, so this is what deleting one actually has to remove.
    func listAllKeys(under prefix: String, in container: StorageContainer) async throws -> [StorageObject]

    /// Whether a delete here can be undone: Azure soft delete, S3 versioning, or
    /// neither. Answering `.unknown` is expected when the account won't say — reading
    /// the policy takes a permission the user may not have.
    func deletionRecovery(in container: StorageContainer) async -> DeletionRecovery
}

extension StorageProvider {
    /// The account this provider is connected to. Lets code holding only a provider —
    /// a drag source, a preview-cache key — name the account without a second
    /// parameter threaded alongside it, and without assuming a cloud.
    var account: ProviderAccount {
        ProviderAccount(kind: kind, name: displayName)
    }

    /// Lists as `listObjects` does, handing each page to `onPage` as it arrives so a
    /// large folder can start showing before the last page is in. Providers that page
    /// override this; the default delivers everything as one page.
    func listObjects(
        in container: StorageContainer,
        prefix: String,
        onPage: @escaping @Sendable ([StorageObject]) async -> Void
    ) async throws {
        await onPage(try await listObjects(in: container, prefix: prefix))
    }
}

enum StorageProviderError: Error, Sendable, Equatable {
    case notImplemented
    /// Azure: a valid Entra token, but the identity lacks a `Storage Blob Data *`
    /// role. Management-plane roles (Owner/Contributor/Reader) do NOT grant data
    /// access — this is surfaced with a specific message, not a generic auth error.
    case dataPlaneForbidden(account: String)
    case unauthorized
    /// Azure's `AuthorizationFailure`: the account's firewall or private-endpoint
    /// rules turned the request away before any role was checked. Reporting it as a
    /// missing role sends people to IAM for a network setting.
    case networkRestricted(account: String)
    /// The Mac's clock is far enough off that the service rejects the signature
    /// (S3's `RequestTimeTooSkewed`).
    case clockSkewed
}
