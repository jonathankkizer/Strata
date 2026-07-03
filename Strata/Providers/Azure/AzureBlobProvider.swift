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
}
