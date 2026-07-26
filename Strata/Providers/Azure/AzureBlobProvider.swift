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

    func fetchMetadata(for object: StorageObject, in container: StorageContainer) async throws -> ObjectMetadata {
        try await client.fetchProperties(container: container.name, blobKey: object.key)
    }

    func objectURL(forKey key: String, in container: StorageContainer) -> URL? {
        // Mirrors AzureBlobRESTClient.blobURL: append each key segment so slashes
        // stay path separators and reserved characters get percent-encoded.
        var url = endpoint.baseURL.appendingPathComponent(container.name)
        for segment in key.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(segment))
        }
        return url
    }

    func download(fromKey key: String, in container: StorageContainer, to destinationURL: URL, onProgress: (@Sendable (Int64, Int64) -> Void)?) async throws {
        try await client.downloadBlob(container: container.name, key: key, to: destinationURL, onProgress: onProgress)
    }

    func upload(from fileURL: URL, toKey key: String, in container: StorageContainer, contentType: String?, plan: UploadPlan, onProgress: (@Sendable (Int64, Int64) -> Void)?) async throws {
        // The plan's predicted operation is the source of truth so the emitted
        // event matches what the UI showed the user before they confirmed.
        switch plan.predictedCommitAPI {
        case .putBlockList:
            try await client.putBlockList(container: container.name, key: key, fileURL: fileURL, contentType: contentType, onProgress: onProgress)
        default:
            try await client.putBlob(container: container.name, key: key, fileURL: fileURL, contentType: contentType, onProgress: onProgress)
        }
    }
}
