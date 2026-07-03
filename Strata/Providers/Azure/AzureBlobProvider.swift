import Foundation

/// Azure Blob Storage provider. No official Azure SDK for Swift exists, so this
/// is a thin REST client over URLSession — which is an advantage: controlling
/// exactly which REST operation each upload uses is what makes deterministic
/// event prediction possible. Stubbed here.
final class AzureBlobProvider: StorageProvider {
    let kind: ProviderKind = .azureBlob
    let displayName: String
    let storageAccount: String
    let credential: AzureCredentialSource

    /// Bearer/Entra calls require this header or the service rejects the token
    /// ("Authentication scheme Bearer is not supported in this version").
    static let minimumBearerAPIVersion = "2021-12-02"

    init(displayName: String, storageAccount: String, credential: AzureCredentialSource) {
        self.displayName = displayName
        self.storageAccount = storageAccount
        self.credential = credential
    }

    func listContainers() async throws -> [StorageContainer] {
        throw StorageProviderError.notImplemented
    }

    func listObjects(in container: StorageContainer, prefix: String) async throws -> [StorageObject] {
        throw StorageProviderError.notImplemented
    }
}
