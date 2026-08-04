import Foundation

/// Remembers which region each bucket lives in.
///
/// `ListBuckets` is global but every object operation is regional, so the region for a
/// given bucket isn't known until something asks. Rather than paying a
/// `GetBucketLocation` round trip before every first use, the provider optimistically
/// tries the configured region and learns from the failure — S3 reports the correct
/// region on a mismatch, which is what `S3Error.wrongRegion` carries.
private actor BucketRegionCache {
    private var byBucket: [String: String] = [:]

    func region(for bucket: String) -> String? { byBucket[bucket] }

    func remember(_ region: String, for bucket: String) { byBucket[bucket] = region }
}

/// Amazon S3, over the hand-rolled SigV4 REST client.
///
/// Credentials come from the AWS CLI's own resolution (`AWSCLICredentialProvider`), so
/// profiles, SSO sessions and assume-role all work exactly as they do in the terminal —
/// the same piggyback principle as the Azure side's `az` dependency.
final class S3Provider: StorageProvider {

    let kind: ProviderKind = .s3
    /// The AWS profile name; what the window title and favorites record.
    let displayName: String

    private let baseEndpoint: S3Endpoint
    private let credentialSource: any AWSCredentialSource
    /// Injectable so tests can drive the region-learning logic through a stubbed
    /// transport; `URLProtocol.registerClass` does not reliably reach `URLSession.shared`.
    private let session: URLSession
    private let regions = BucketRegionCache()

    init(
        profile: String,
        region: String = "us-east-1",
        customHost: URL? = nil,
        credentialSource: (any AWSCredentialSource)? = nil,
        session: URLSession = .shared
    ) {
        self.displayName = profile
        self.baseEndpoint = S3Endpoint(region: region, customHost: customHost)
        self.credentialSource = credentialSource
            ?? AWSCLICredentialProvider(configuration: .init(profile: profile))
        self.session = session
    }

    /// Kept so existing call sites that only have a display name still compile; the
    /// profile *is* the display name.
    convenience init(displayName: String) {
        self.init(profile: displayName)
    }

    // MARK: - Reads

    func listContainers() async throws -> [StorageContainer] {
        // ListBuckets is a global operation — no per-bucket region involved.
        try await client(for: baseEndpoint).listBuckets()
    }

    func listObjects(in container: StorageContainer, prefix: String) async throws -> [StorageObject] {
        try await withRegionalClient(for: container.name) { client in
            try await client.listAllObjects(bucket: container.name, prefix: prefix)
        }
    }

    func fetchMetadata(for object: StorageObject, in container: StorageContainer) async throws -> ObjectMetadata {
        try await withRegionalClient(for: container.name) { client in
            try await client.headObject(bucket: container.name, key: object.key)
        }
    }

    func objectURL(forKey key: String, in container: StorageContainer) -> URL? {
        // The canonical `s3://bucket/key` URI: what every AWS tool accepts, and stable
        // regardless of which regional endpoint we happen to be talking to.
        var components = URLComponents()
        components.scheme = "s3"
        components.host = container.name
        components.path = "/" + key
        return components.url
    }

    func download(
        fromKey key: String,
        in container: StorageContainer,
        to destinationURL: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
        try await withRegionalClient(for: container.name) { client in
            try await client.downloadObject(
                bucket: container.name,
                key: key,
                to: destinationURL,
                onProgress: onProgress
            )
        }
    }

    // MARK: - Writes

    func upload(
        from fileURL: URL,
        toKey key: String,
        in container: StorageContainer,
        contentType: String?,
        plan: UploadPlan,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
        try await withRegionalClient(for: container.name) { client in
            // The plan is the source of truth, so the object is written by the operation
            // whose event the UI already predicted. Choosing differently here would make
            // the prediction a lie.
            if plan.usesMultipleRequests {
                try await client.putObjectMultipart(
                    bucket: container.name,
                    key: key,
                    fileURL: fileURL,
                    contentType: contentType,
                    partSize: Int(plan.singleShotThreshold),
                    onProgress: onProgress
                )
            } else {
                try await client.putObject(
                    bucket: container.name,
                    key: key,
                    fileURL: fileURL,
                    contentType: contentType,
                    onProgress: onProgress
                )
            }
        }
    }

    // MARK: - Region resolution

    private func client(for endpoint: S3Endpoint) -> S3RESTClient {
        S3RESTClient(endpoint: endpoint, credentialSource: credentialSource, session: session)
    }

    /// Runs `body` against the right regional endpoint for `bucket`.
    ///
    /// First use of a bucket optimistically assumes the profile's region. If it lives
    /// elsewhere, S3 says so — verified against live S3, that arrives as a 403 carrying
    /// `x-amz-bucket-region` rather than a redirect — and the operation is retried once
    /// against the correct region, which is then remembered for the session.
    ///
    /// Retried exactly once: a second `wrongRegion` would mean S3 is contradicting
    /// itself, and looping on that would be worse than surfacing it.
    private func withRegionalClient<T>(
        for bucket: String,
        _ body: (S3RESTClient) async throws -> T
    ) async throws -> T {
        let knownRegion = await regions.region(for: bucket)
        let endpoint = knownRegion.map { baseEndpoint.with(region: $0) } ?? baseEndpoint

        do {
            return try await body(client(for: endpoint))
        } catch let error as S3Error {
            guard case let .wrongRegion(_, correctRegion) = error,
                  let correctRegion,
                  correctRegion != endpoint.region else {
                throw error
            }
            await regions.remember(correctRegion, for: bucket)
            return try await body(client(for: baseEndpoint.with(region: correctRegion)))
        }
    }
}
