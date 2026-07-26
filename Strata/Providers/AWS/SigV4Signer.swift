import CryptoKit
import Foundation

/// Signs requests with AWS Signature Version 4.
///
/// Hand-rolled rather than taken from the AWS SDK, for the same reason the Azure side
/// is: the app needs a handful of S3 operations, the SDK would be the project's first
/// SPM dependency (plus its C runtime) in a hand-written pbxproj that currently
/// notarizes cleanly, and the SDK's main draw — the credential provider chain — is
/// already obtained for free by asking the `aws` CLI.
///
/// SigV4 is unforgiving but completely specified, and every step is a pure function
/// over strings. That makes it exactly the kind of thing to unit-test hard, which is
/// what `SigV4SignerTests` does against AWS's own published example vectors.
///
/// The canonicalisation rules that are easy to get wrong, and are therefore spelled
/// out here:
/// - Header names lowercased, values trimmed, sorted by name; the signed-headers list
///   must match the canonical headers exactly.
/// - Query parameters sorted by encoded name, then encoded value.
/// - The path is URI-encoded *except* for `/`, and for S3 specifically it is encoded
///   only once (S3 is the documented exception to double-encoding).
/// - `host` and `x-amz-date` are always signed. `x-amz-content-sha256` is required by
///   S3 and is also signed.
struct SigV4Signer: Sendable {

    let region: String
    let service: String

    init(region: String, service: String = "s3") {
        self.region = region
        self.service = service
    }

    /// What a request body hashes to. Streaming uploads can't be hashed up front
    /// without reading the whole file, so S3 permits the literal `UNSIGNED-PAYLOAD`
    /// over HTTPS.
    enum Payload: Sendable {
        case empty
        case data(Data)
        case unsigned
        /// A precomputed hex SHA-256, for a body already hashed elsewhere.
        case precomputedHash(String)

        static let emptyStringSHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        static let unsignedLiteral = "UNSIGNED-PAYLOAD"

        var hashValue: String {
            switch self {
            case .empty: return Self.emptyStringSHA256
            case .data(let data): return SigV4Signer.hexSHA256(data)
            case .unsigned: return Self.unsignedLiteral
            case .precomputedHash(let hash): return hash
            }
        }
    }

    /// Adds `Authorization`, `x-amz-date`, `x-amz-content-sha256` and (when the
    /// credentials are temporary) `x-amz-security-token` to `request`.
    func sign(
        _ request: URLRequest,
        payload: Payload,
        credentials: AWSCredentials,
        date: Date
    ) -> URLRequest {
        var signed = request
        let timestamp = Self.amzDate(date)
        let payloadHash = payload.hashValue

        signed.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        signed.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        if let sessionToken = credentials.sessionToken {
            signed.setValue(sessionToken, forHTTPHeaderField: "x-amz-security-token")
        }
        if let host = request.url?.host, signed.value(forHTTPHeaderField: "host") == nil {
            // URLSession sets Host itself, but it must be present to be signed.
            signed.setValue(host, forHTTPHeaderField: "host")
        }

        let headers = signed.allHTTPHeaderFields ?? [:]
        let canonical = Self.canonicalRequest(
            method: signed.httpMethod ?? "GET",
            url: signed.url,
            headers: headers,
            payloadHash: payloadHash
        )
        let scope = "\(Self.dateStamp(date))/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            timestamp,
            scope,
            Self.hexSHA256(Data(canonical.request.utf8)),
        ].joined(separator: "\n")

        let signature = Self.hex(Self.hmac(
            key: signingKey(date: date, secret: credentials.secretAccessKey),
            data: Data(stringToSign.utf8)
        ))

        let authorization = "AWS4-HMAC-SHA256 "
            + "Credential=\(credentials.accessKeyID)/\(scope), "
            + "SignedHeaders=\(canonical.signedHeaders), "
            + "Signature=\(signature)"
        signed.setValue(authorization, forHTTPHeaderField: "Authorization")
        return signed
    }

    // MARK: - Canonical request

    struct CanonicalRequest: Equatable {
        var request: String
        var signedHeaders: String
    }

    static func canonicalRequest(
        method: String,
        url: URL?,
        headers: [String: String],
        payloadHash: String
    ) -> CanonicalRequest {
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }

        // Header names are matched case-insensitively and signed lowercased. Values
        // are trimmed; internal whitespace is left alone, which is correct for
        // everything S3 sends.
        var normalized: [(String, String)] = headers.map {
            ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces))
        }
        normalized.sort { $0.0 < $1.0 }

        let canonicalHeaders = normalized.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = normalized.map(\.0).joined(separator: ";")

        return CanonicalRequest(
            request: [
                method.uppercased(),
                canonicalPath(components?.percentEncodedPath ?? "/"),
                canonicalQuery(components?.percentEncodedQuery),
                canonicalHeaders,
                signedHeaders,
                payloadHash,
            ].joined(separator: "\n"),
            signedHeaders: signedHeaders
        )
    }

    /// S3 signs the path encoded exactly once, so an already-percent-encoded path is
    /// used as-is. An empty path signs as "/".
    static func canonicalPath(_ percentEncodedPath: String) -> String {
        percentEncodedPath.isEmpty ? "/" : percentEncodedPath
    }

    /// Sorted by encoded name then encoded value, `=` for valueless parameters.
    static func canonicalQuery(_ percentEncodedQuery: String?) -> String {
        guard let percentEncodedQuery, !percentEncodedQuery.isEmpty else { return "" }
        let pairs = percentEncodedQuery.split(separator: "&", omittingEmptySubsequences: true).map { pair -> (String, String) in
            guard let separator = pair.firstIndex(of: "=") else { return (String(pair), "") }
            return (String(pair[pair.startIndex..<separator]), String(pair[pair.index(after: separator)...]))
        }
        return pairs
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    /// Percent-encodes a path segment per SigV4's rules: unreserved characters pass
    /// through, everything else is `%XX` uppercase. Notably stricter than
    /// `URLComponents`, which leaves several sub-delimiters unescaped.
    static func encodePathSegment(_ segment: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    /// Encodes an object key into a URL path, keeping `/` as a separator so prefixes
    /// stay real path components.
    static func encodeKey(_ key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: false)
            .map { encodePathSegment(String($0)) }
            .joined(separator: "/")
    }

    // MARK: - Signing key

    /// The derived signing key: HMAC chained over date, region, service, terminator.
    func signingKey(date: Date, secret: String) -> Data {
        let dateKey = Self.hmac(key: Data("AWS4\(secret)".utf8), data: Data(Self.dateStamp(date).utf8))
        let regionKey = Self.hmac(key: dateKey, data: Data(region.utf8))
        let serviceKey = Self.hmac(key: regionKey, data: Data(service.utf8))
        return Self.hmac(key: serviceKey, data: Data("aws4_request".utf8))
    }

    // MARK: - Primitives

    /// `yyyyMMdd'T'HHmmss'Z'`, always UTC. Hand-formatted rather than via
    /// DateFormatter: a formatter picks up the host locale and calendar unless every
    /// knob is set, and getting this wrong fails every request with a signature error.
    static func amzDate(_ date: Date) -> String {
        let parts = utcComponents(date)
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second
        )
    }

    /// `yyyyMMdd`, always UTC — the credential scope's date.
    static func dateStamp(_ date: Date) -> String {
        let parts = utcComponents(date)
        return String(format: "%04d%02d%02d", parts.year, parts.month, parts.day)
    }

    private static func utcComponents(
        _ date: Date
    ) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return (parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    static func hexSHA256(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
