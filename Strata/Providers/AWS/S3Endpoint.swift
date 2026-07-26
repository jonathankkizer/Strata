import Foundation

/// Where S3 requests go, and in which addressing style.
///
/// Two axes, both of which matter:
///
/// **Addressing.** AWS wants virtual-hosted style (`bucket.s3.region.amazonaws.com`)
/// and has deprecated path-style for new buckets. But S3-compatible services — MinIO,
/// Backblaze, Ceph — generally require path-style (`host/bucket/key`), and a bucket
/// name that isn't DNS-safe (dots, uppercase) can't be virtual-hosted at all.
///
/// **Host.** A custom host is what makes MinIO/R2/Backblaze work, which is both a real
/// product feature and the only way to integration-test this without an AWS account.
struct S3Endpoint: Sendable, Hashable {

    enum Addressing: Sendable, Hashable {
        case virtualHosted
        case path
    }

    /// Region used for signing and, for AWS, in the hostname.
    var region: String
    /// Non-nil for an S3-compatible service. Nil means real AWS.
    var customHost: URL?
    var addressing: Addressing

    init(region: String, customHost: URL? = nil, addressing: Addressing? = nil) {
        self.region = region
        self.customHost = customHost
        // A custom host almost always means path-style; AWS defaults to virtual-hosted.
        self.addressing = addressing ?? (customHost == nil ? .virtualHosted : .path)
    }

    /// A bucket name can only be a hostname label if it's DNS-safe. Dots break TLS
    /// certificate matching against `*.s3.amazonaws.com`, and uppercase isn't valid in
    /// a hostname — so those buckets must be addressed path-style regardless of
    /// configuration.
    static func isDNSCompatible(bucket: String) -> Bool {
        guard (3...63).contains(bucket.count) else { return false }
        guard !bucket.contains(".") else { return false }
        guard bucket == bucket.lowercased() else { return false }
        guard let first = bucket.first, let last = bucket.last,
              first.isLetter || first.isNumber, last.isLetter || last.isNumber else { return false }
        return bucket.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
    }

    /// The service-level URL, for operations with no bucket (ListBuckets).
    var serviceURL: URL {
        if let customHost { return customHost }
        // us-east-1 is reachable at the regionless endpoint; every other region needs
        // its own, or S3 answers 301 with no useful body.
        let host = region == "us-east-1" ? "s3.amazonaws.com" : "s3.\(region).amazonaws.com"
        return URL(string: "https://\(host)")!
    }

    /// The base URL for a bucket, in whichever addressing style applies.
    func bucketURL(_ bucket: String) -> URL {
        let usePathStyle = addressing == .path || !Self.isDNSCompatible(bucket: bucket)
        if usePathStyle {
            return serviceURL.appendingPathComponent(bucket)
        }
        if let customHost {
            // Virtual-hosted against a custom host: prefix the bucket onto its host.
            guard let host = customHost.host,
                  var components = URLComponents(url: customHost, resolvingAgainstBaseURL: false) else {
                return customHost.appendingPathComponent(bucket)
            }
            components.host = "\(bucket).\(host)"
            return components.url ?? customHost.appendingPathComponent(bucket)
        }
        let host = region == "us-east-1" ? "s3.amazonaws.com" : "s3.\(region).amazonaws.com"
        return URL(string: "https://\(bucket).\(host)")!
    }

    /// The URL for an object. The key is encoded with SigV4's stricter rules and
    /// appended without re-encoding, so what is signed matches what is sent.
    func objectURL(bucket: String, key: String) -> URL? {
        let base = bucketURL(bucket)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let encodedKey = SigV4Signer.encodeKey(key)
        let basePath = components.percentEncodedPath
        components.percentEncodedPath = basePath.hasSuffix("/")
            ? basePath + encodedKey
            : basePath + "/" + encodedKey
        return components.url
    }

    /// Same region, different host — used when S3 reports that a bucket lives
    /// elsewhere and the request has to be reissued against the right endpoint.
    func with(region newRegion: String) -> S3Endpoint {
        S3Endpoint(region: newRegion, customHost: customHost, addressing: addressing)
    }
}
