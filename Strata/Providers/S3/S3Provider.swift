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

    func upload(_ data: Data, toKey key: String, in container: StorageContainer, contentType: String?, plan: UploadPlan, onProgress: (@Sendable (Int64, Int64) -> Void)?) async throws {
        throw StorageProviderError.notImplemented
    }
}
