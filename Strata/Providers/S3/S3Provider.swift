import Foundation

/// Amazon S3 provider. v1 sits on the AWS SDK for Swift and its standard
/// credential-provider chain (profiles, SSO, assume-role, static keys).
/// Stubbed here — network + SDK wiring is the next implementation step.
final class S3Provider: StorageProvider {
    let kind: ProviderKind = .s3
    let displayName: String

    init(displayName: String) {
        self.displayName = displayName
    }

    func listContainers() async throws -> [StorageContainer] {
        throw StorageProviderError.notImplemented
    }

    func listObjects(in container: StorageContainer, prefix: String) async throws -> [StorageObject] {
        throw StorageProviderError.notImplemented
    }

    func fetchMetadata(for object: StorageObject, in container: StorageContainer) async throws -> ObjectMetadata {
        throw StorageProviderError.notImplemented
    }

    func objectURL(forKey key: String, in container: StorageContainer) -> URL? {
        // The canonical s3:// URI is well-defined from bucket + key even while the
        // SDK-backed data path is still stubbed.
        var components = URLComponents()
        components.scheme = "s3"
        components.host = container.name
        components.path = "/" + key
        return components.url
    }

    func download(fromKey key: String, in container: StorageContainer, to destinationURL: URL, onProgress: (@Sendable (Int64, Int64) -> Void)?) async throws {
        throw StorageProviderError.notImplemented
    }

    func upload(from fileURL: URL, toKey key: String, in container: StorageContainer, contentType: String?, plan: UploadPlan, onProgress: (@Sendable (Int64, Int64) -> Void)?) async throws {
        throw StorageProviderError.notImplemented
    }
}
