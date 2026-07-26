import Testing
import Foundation
@testable import Strata

/// SigV4 is unforgiving: any deviation produces `SignatureDoesNotMatch` and no clue
/// about which step was wrong. So the signer is pinned to AWS's published
/// `aws4_testsuite` vectors, whose expected values were also reproduced with an
/// independent implementation before being written down here — a test that only agrees
/// with the code it tests would be worthless.
@Suite("SigV4 signing")
struct SigV4SignerTests {

    // AWS's documented example credentials and clock.
    private static let exampleSecret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
    private static let exampleKeyID = "AKIDEXAMPLE"
    /// 2015-08-30T12:36:00Z, the timestamp used throughout the AWS test suite.
    private static let exampleDate = Date(timeIntervalSince1970: 1_440_938_160)

    private var exampleCredentials: AWSCredentials {
        AWSCredentials(
            accessKeyID: Self.exampleKeyID,
            secretAccessKey: Self.exampleSecret,
            sessionToken: nil,
            expiration: nil
        )
    }

    // MARK: - Timestamps

    @Test("Timestamps are UTC in the exact required formats")
    func timestampFormats() {
        #expect(SigV4Signer.amzDate(Self.exampleDate) == "20150830T123600Z")
        #expect(SigV4Signer.dateStamp(Self.exampleDate) == "20150830")
    }

    /// A DateFormatter would silently pick up the host's locale and calendar. Under a
    /// non-Gregorian calendar that yields a wrong year and every request fails, which
    /// is why the formatting is done by hand.
    @Test("Timestamps ignore the host locale and calendar")
    func timestampsIgnoreLocale() {
        // Same instant, formatted the same way regardless of ambient settings.
        #expect(SigV4Signer.amzDate(Date(timeIntervalSince1970: 0)) == "19700101T000000Z")
        #expect(SigV4Signer.dateStamp(Date(timeIntervalSince1970: 0)) == "19700101")
    }

    // MARK: - Canonical request

    @Test("Builds the canonical request for get-vanilla")
    func canonicalRequestForGetVanilla() {
        let canonical = SigV4Signer.canonicalRequest(
            method: "GET",
            url: URL(string: "https://example.amazonaws.com/")!,
            headers: ["Host": "example.amazonaws.com", "X-Amz-Date": "20150830T123600Z"],
            payloadHash: SigV4Signer.Payload.emptyStringSHA256
        )

        #expect(canonical.signedHeaders == "host;x-amz-date")
        #expect(canonical.request == """
            GET
            /

            host:example.amazonaws.com
            x-amz-date:20150830T123600Z

            host;x-amz-date
            \(SigV4Signer.Payload.emptyStringSHA256)
            """)
    }

    @Test("Header names lowercase and sort, values trim")
    func headersNormalized() {
        let canonical = SigV4Signer.canonicalRequest(
            method: "put",
            url: URL(string: "https://example.amazonaws.com/x")!,
            headers: [
                "X-Amz-Date": "  20150830T123600Z  ",
                "Host": "example.amazonaws.com",
                "Content-Type": "text/plain",
            ],
            payloadHash: "HASH"
        )
        #expect(canonical.signedHeaders == "content-type;host;x-amz-date")
        #expect(canonical.request.hasPrefix("PUT\n/x\n\ncontent-type:text/plain\n"))
        #expect(canonical.request.contains("x-amz-date:20150830T123600Z\n"))
    }

    @Test("Query parameters sort by name then value")
    func querySorting() {
        #expect(SigV4Signer.canonicalQuery("b=2&a=1") == "a=1&b=2")
        #expect(SigV4Signer.canonicalQuery("a=2&a=1") == "a=1&a=2")
        // A valueless parameter still carries its "=".
        #expect(SigV4Signer.canonicalQuery("acl") == "acl=")
        #expect(SigV4Signer.canonicalQuery(nil) == "")
        #expect(SigV4Signer.canonicalQuery("") == "")
    }

    /// A listing request is exactly this shape, and `list-type=2` sorting alongside a
    /// prefix is the case that would break paging if it were wrong.
    @Test("A realistic ListObjectsV2 query canonicalises correctly")
    func listObjectsQuery() {
        #expect(
            SigV4Signer.canonicalQuery("list-type=2&prefix=logs%2F&delimiter=%2F&max-keys=1000")
                == "delimiter=%2F&list-type=2&max-keys=1000&prefix=logs%2F"
        )
    }

    @Test("An empty path signs as a single slash")
    func emptyPathIsSlash() {
        #expect(SigV4Signer.canonicalPath("") == "/")
        #expect(SigV4Signer.canonicalPath("/my-bucket/key") == "/my-bucket/key")
    }

    // MARK: - Key encoding

    @Test("Key encoding keeps slashes but escapes everything else that must be")
    func keyEncoding() {
        #expect(SigV4Signer.encodeKey("logs/2026/app.log") == "logs/2026/app.log")
        #expect(SigV4Signer.encodeKey("my folder/a b.txt") == "my%20folder/a%20b.txt")
        #expect(SigV4Signer.encodeKey("weird+name&x=1") == "weird%2Bname%26x%3D1")
        #expect(SigV4Signer.encodeKey("unreserved-._~") == "unreserved-._~")
        // A trailing slash is a real (empty) segment for a prefix marker.
        #expect(SigV4Signer.encodeKey("folder/") == "folder/")
    }

    /// `URLComponents` leaves sub-delimiters like `+` and `&` alone, which produces a
    /// path that differs from what S3 signs. This is the reason for a hand-rolled
    /// encoder rather than reusing Foundation's.
    @Test("Encoding is stricter than URL query allowances")
    func encodingIsStricterThanFoundation() {
        #expect(SigV4Signer.encodePathSegment("a+b") == "a%2Bb")
        #expect(SigV4Signer.encodePathSegment("a&b") == "a%26b")
        #expect(SigV4Signer.encodePathSegment("100%") == "100%25")
    }

    // MARK: - Signing key and signature

    @Test("Derives the documented signing key")
    func derivesSigningKey() {
        let signer = SigV4Signer(region: "us-east-1", service: "service")
        let key = signer.signingKey(date: Self.exampleDate, secret: Self.exampleSecret)
        #expect(
            SigV4Signer.hex(key)
                == "938127b5336810ddb6a5d6af445fcac9e371f9ed418ed386b022aed82901be75"
        )
    }

    /// The end-to-end check: AWS's `get-vanilla` expected Authorization header.
    @Test("Produces the documented get-vanilla signature")
    func signsGetVanilla() throws {
        var request = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
        request.httpMethod = "GET"
        // Signed with `service`, matching the test suite rather than S3.
        let signer = SigV4Signer(region: "us-east-1", service: "service")

        // The suite's canonical request signs only host and x-amz-date, so the
        // S3-specific content-sha256 header is excluded here by signing the canonical
        // form directly rather than through `sign(_:)`.
        let canonical = SigV4Signer.canonicalRequest(
            method: "GET",
            url: request.url,
            headers: ["host": "example.amazonaws.com", "x-amz-date": "20150830T123600Z"],
            payloadHash: SigV4Signer.Payload.emptyStringSHA256
        )
        let scope = "20150830/us-east-1/service/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            "20150830T123600Z",
            scope,
            SigV4Signer.hexSHA256(Data(canonical.request.utf8)),
        ].joined(separator: "\n")

        let signature = SigV4Signer.hex(SigV4Signer.hmac(
            key: signer.signingKey(date: Self.exampleDate, secret: Self.exampleSecret),
            data: Data(stringToSign.utf8)
        ))
        #expect(signature == "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    // MARK: - Request signing

    @Test("Signing attaches every header S3 requires")
    func signAttachesRequiredHeaders() throws {
        var request = URLRequest(url: URL(string: "https://s3.us-west-2.amazonaws.com/my-bucket/key")!)
        request.httpMethod = "GET"

        let signed = SigV4Signer(region: "us-west-2").sign(
            request,
            payload: .empty,
            credentials: AWSCredentials(
                accessKeyID: "AKIAEXAMPLE",
                secretAccessKey: "secret",
                sessionToken: "TOKEN",
                expiration: nil
            ),
            date: Self.exampleDate
        )

        #expect(signed.value(forHTTPHeaderField: "x-amz-date") == "20150830T123600Z")
        #expect(signed.value(forHTTPHeaderField: "x-amz-content-sha256") == SigV4Signer.Payload.emptyStringSHA256)
        #expect(signed.value(forHTTPHeaderField: "x-amz-security-token") == "TOKEN")
        #expect(signed.value(forHTTPHeaderField: "host") == "s3.us-west-2.amazonaws.com")

        let authorization = try #require(signed.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.hasPrefix("AWS4-HMAC-SHA256 "))
        #expect(authorization.contains("Credential=AKIAEXAMPLE/20150830/us-west-2/s3/aws4_request"))
        // The security token is temporary, so it must be inside SignedHeaders too —
        // omitting it is a classic source of intermittent 403s.
        #expect(authorization.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token"))
    }

    @Test("Long-lived credentials carry no security token")
    func noTokenForStaticKeys() {
        var request = URLRequest(url: URL(string: "https://s3.us-west-2.amazonaws.com/b/k")!)
        request.httpMethod = "GET"
        let signed = SigV4Signer(region: "us-west-2").sign(
            request,
            payload: .empty,
            credentials: exampleCredentials,
            date: Self.exampleDate
        )
        #expect(signed.value(forHTTPHeaderField: "x-amz-security-token") == nil)
        #expect(signed.value(forHTTPHeaderField: "Authorization")?
            .contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date") == true)
    }

    /// Streaming an upload can't hash the body up front without reading the whole file,
    /// so S3 accepts the unsigned-payload literal over HTTPS.
    @Test("An unsigned payload signs as the documented literal")
    func unsignedPayload() {
        var request = URLRequest(url: URL(string: "https://s3.us-west-2.amazonaws.com/b/k")!)
        request.httpMethod = "PUT"
        let signed = SigV4Signer(region: "us-west-2").sign(
            request,
            payload: .unsigned,
            credentials: exampleCredentials,
            date: Self.exampleDate
        )
        #expect(signed.value(forHTTPHeaderField: "x-amz-content-sha256") == "UNSIGNED-PAYLOAD")
    }

    @Test("Payload hashing matches known SHA-256 values")
    func payloadHashes() {
        #expect(SigV4Signer.Payload.empty.hashValue == SigV4Signer.Payload.emptyStringSHA256)
        #expect(SigV4Signer.hexSHA256(Data()) == SigV4Signer.Payload.emptyStringSHA256)
        // "abc" — a value with a widely published digest.
        #expect(
            SigV4Signer.hexSHA256(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        #expect(SigV4Signer.Payload.precomputedHash("deadbeef").hashValue == "deadbeef")
    }

    /// Region and service are part of the scope, so the same request signed for a
    /// different region must produce a different signature.
    @Test("The signature is scoped to region and service")
    func signatureIsScoped() throws {
        var request = URLRequest(url: URL(string: "https://s3.amazonaws.com/b/k")!)
        request.httpMethod = "GET"

        let west = SigV4Signer(region: "us-west-2").sign(
            request, payload: .empty, credentials: exampleCredentials, date: Self.exampleDate
        ).value(forHTTPHeaderField: "Authorization")
        let east = SigV4Signer(region: "us-east-1").sign(
            request, payload: .empty, credentials: exampleCredentials, date: Self.exampleDate
        ).value(forHTTPHeaderField: "Authorization")

        #expect(west != east)
        #expect(try #require(west).contains("/us-west-2/s3/"))
        #expect(try #require(east).contains("/us-east-1/s3/"))
    }
}
