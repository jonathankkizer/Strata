import Foundation

/// Azure Blob Storage provider. No official Azure SDK for Swift exists, so this
/// sits on a thin REST client over URLSession — which is an advantage: controlling
/// exactly which REST operation each call uses is what makes deterministic event
/// prediction possible. Reads (list) are wired; writes come next.
final class AzureBlobProvider: StorageProvider {
    let kind: ProviderKind = .azureBlob
    let displayName: String
    let endpoint: AzureStorageEndpoint

    private let client: AzureBlobRESTClient

    /// Bearer/Entra calls require this header or the service rejects the token
    /// ("Authentication scheme Bearer is not supported in this version").
    static let minimumBearerAPIVersion = "2021-12-02"

    init(
        displayName: String,
        endpoint: AzureStorageEndpoint,
        tokenSource: any AzureTokenSource,
        apiVersion: String = AzureBlobProvider.minimumBearerAPIVersion,
        session: URLSession = .shared
    ) {
        self.displayName = displayName
        self.endpoint = endpoint
        self.client = AzureBlobRESTClient(
            endpoint: endpoint,
            tokenSource: tokenSource,
            apiVersion: apiVersion,
            session: session
        )
    }

    func listContainers() async throws -> [StorageContainer] {
        try await client.listAllContainers()
    }

    func listObjects(in container: StorageContainer, prefix: String) async throws -> [StorageObject] {
        try await client.listAllBlobs(inContainer: container.name, prefix: prefix, delimiter: "/")
    }

    func listObjects(
        in container: StorageContainer,
        prefix: String,
        onPage: @escaping @Sendable ([StorageObject]) async -> Void
    ) async throws {
        _ = try await client.listAllBlobs(inContainer: container.name, prefix: prefix, delimiter: "/", onPage: onPage)
    }

    func fetchMetadata(for object: StorageObject, in container: StorageContainer) async throws -> ObjectMetadata {
        try await client.fetchProperties(container: container.name, blobKey: object.key)
    }

    func objectURL(forKey key: String, in container: StorageContainer) -> URL? {
        endpoint.url(container: container.name, key: key)
    }

    func download(fromKey key: String, in container: StorageContainer, to destinationURL: URL, onProgress: (@Sendable (Int64, Int64) -> Void)?) async throws {
        try await client.downloadBlob(container: container.name, key: key, to: destinationURL, onProgress: onProgress)
    }

    func delete(key: String, in container: StorageContainer) async throws {
        try await client.deleteBlob(container: container.name, key: key)
    }

    func listAllKeys(under prefix: String, in container: StorageContainer) async throws -> [StorageObject] {
        // No delimiter: the service stops collapsing folders and returns every blob
        // beneath the prefix, however deep.
        try await client.listAllBlobs(inContainer: container.name, prefix: prefix, delimiter: nil)
    }

    func deletionRecovery(in container: StorageContainer) async -> DeletionRecovery {
        await retention.value {
            let policy = try await client.retentionPolicy()
            return DeletionRecovery.from(
                versioningEnabled: policy.versioningEnabled,
                retentionDays: policy.retentionDays
            )
        }
    }

    /// Retention is an account-level setting, so it is read once and reused for every
    /// container — and a failure is remembered too, rather than re-asking for a
    /// permission the user has already been refused.
    private let retention = RecoveryCache()

    func upload(from fileURL: URL, toKey key: String, in container: StorageContainer, contentType: String?, plan: UploadPlan, onProgress: (@Sendable (Int64, Int64) -> Void)?) async throws {
        // The plan's predicted operation is the source of truth so the emitted
        // event matches what the UI showed the user before they confirmed.
        switch plan.azureCommitAPI {
        case .putBlockList:
            try await client.putBlockList(container: container.name, key: key, fileURL: fileURL, contentType: contentType, onProgress: onProgress)
        default:
            try await client.putBlob(container: container.name, key: key, fileURL: fileURL, contentType: contentType, onProgress: onProgress)
        }
    }
}
