import Testing
import Foundation
@testable import Strata

@Suite("S3 endpoint addressing")
struct S3EndpointTests {

    @Test("us-east-1 uses the regionless host; other regions are explicit")
    func serviceHosts() {
        #expect(S3Endpoint(region: "us-east-1").serviceURL.absoluteString == "https://s3.amazonaws.com")
        #expect(S3Endpoint(region: "eu-west-2").serviceURL.absoluteString == "https://s3.eu-west-2.amazonaws.com")
    }

    @Test("AWS buckets are virtual-hosted by default")
    func virtualHostedByDefault() {
        let endpoint = S3Endpoint(region: "us-west-2")
        #expect(endpoint.bucketURL("my-bucket").absoluteString == "https://my-bucket.s3.us-west-2.amazonaws.com")
        #expect(endpoint.objectURL(bucket: "my-bucket", key: "logs/app.log")?.absoluteString
            == "https://my-bucket.s3.us-west-2.amazonaws.com/logs/app.log")
    }

    /// A dot in a bucket name breaks TLS against `*.s3.amazonaws.com`, and uppercase
    /// isn't legal in a hostname — so these have to fall back to path-style whatever
    /// the configuration says, or requests fail in a way that looks like a network
    /// problem.
    @Test("Non-DNS-safe bucket names fall back to path style")
    func nonDNSSafeBucketsUsePathStyle() {
        let endpoint = S3Endpoint(region: "us-east-1")
        #expect(endpoint.bucketURL("my.dotted.bucket").absoluteString
            == "https://s3.amazonaws.com/my.dotted.bucket")
        #expect(endpoint.bucketURL("MixedCase").absoluteString
            == "https://s3.amazonaws.com/MixedCase")
        #expect(endpoint.bucketURL("ok-bucket").absoluteString
            == "https://ok-bucket.s3.amazonaws.com")
    }

    @Test("DNS compatibility follows S3's naming rules")
    func dnsCompatibility() {
        #expect(S3Endpoint.isDNSCompatible(bucket: "my-bucket"))
        #expect(S3Endpoint.isDNSCompatible(bucket: "abc"))
        #expect(S3Endpoint.isDNSCompatible(bucket: "with.dot") == false)
        #expect(S3Endpoint.isDNSCompatible(bucket: "Upper") == false)
        #expect(S3Endpoint.isDNSCompatible(bucket: "-leading") == false)
        #expect(S3Endpoint.isDNSCompatible(bucket: "trailing-") == false)
        #expect(S3Endpoint.isDNSCompatible(bucket: "ab") == false)
        #expect(S3Endpoint.isDNSCompatible(bucket: "under_score") == false)
        #expect(S3Endpoint.isDNSCompatible(bucket: String(repeating: "a", count: 64)) == false)
    }

    /// The MinIO/R2/Backblaze case — and the only way to integration-test this without
    /// an AWS account.
    @Test("A custom host defaults to path style")
    func customHostUsesPathStyle() {
        let endpoint = S3Endpoint(region: "us-east-1", customHost: URL(string: "http://localhost:9000")!)
        #expect(endpoint.addressing == .path)
        #expect(endpoint.bucketURL("data").absoluteString == "http://localhost:9000/data")
        #expect(endpoint.objectURL(bucket: "data", key: "a/b.txt")?.absoluteString
            == "http://localhost:9000/data/a/b.txt")
    }

    @Test("A custom host can still be virtual-hosted when asked")
    func customHostVirtualHosted() {
        let endpoint = S3Endpoint(
            region: "auto",
            customHost: URL(string: "https://accountid.r2.cloudflarestorage.com")!,
            addressing: .virtualHosted
        )
        #expect(endpoint.bucketURL("assets").absoluteString
            == "https://assets.accountid.r2.cloudflarestorage.com")
    }

    /// Keys with spaces and reserved characters have to survive the round trip, and
    /// must be encoded the same way the signer encodes them or every request 403s.
    @Test("Object keys are encoded consistently with the signer")
    func keyEncodingMatchesSigner() {
        let endpoint = S3Endpoint(region: "us-east-1")
        #expect(endpoint.objectURL(bucket: "buk", key: "my folder/a b.txt")?.absoluteString
            == "https://buk.s3.amazonaws.com/my%20folder/a%20b.txt")
        #expect(endpoint.objectURL(bucket: "buk", key: "plus+sign.txt")?.absoluteString
            == "https://buk.s3.amazonaws.com/plus%2Bsign.txt")
        // Under 3 characters isn't a legal S3 bucket name, so it can't be a hostname
        // label either and correctly falls back to path style.
        #expect(endpoint.objectURL(bucket: "b", key: "k.txt")?.absoluteString
            == "https://s3.amazonaws.com/b/k.txt")
    }

    @Test("Re-pointing at another region keeps the other settings")
    func withRegionPreservesConfiguration() {
        let original = S3Endpoint(region: "us-east-1", customHost: URL(string: "http://localhost:9000")!)
        let moved = original.with(region: "eu-west-1")
        #expect(moved.region == "eu-west-1")
        #expect(moved.customHost == original.customHost)
        #expect(moved.addressing == original.addressing)
    }
}

@Suite("S3 XML parsing")
struct S3XMLParsingTests {

    @Test("Parses ListBuckets")
    func parsesBuckets() throws {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ListAllMyBucketsResult>
              <Owner><ID>abc</ID><DisplayName>me</DisplayName></Owner>
              <Buckets>
                <Bucket><Name>logs</Name><CreationDate>2026-01-01T00:00:00.000Z</CreationDate></Bucket>
                <Bucket><Name>data-lake</Name><CreationDate>2026-02-01T00:00:00.000Z</CreationDate></Bucket>
              </Buckets>
            </ListAllMyBucketsResult>
            """
        let buckets = try S3BucketListXMLParser().parse(Data(xml.utf8))
        #expect(buckets.map(\.name) == ["logs", "data-lake"])
    }

    /// The owner's `DisplayName` is also a `Name`-adjacent element; picking it up as a
    /// bucket would put a phantom row in the sidebar.
    @Test("The owner block doesn't become a bucket")
    func ownerIsNotABucket() throws {
        let xml = """
            <ListAllMyBucketsResult>
              <Owner><ID>abc</ID><DisplayName>me</DisplayName></Owner>
              <Buckets></Buckets>
            </ListAllMyBucketsResult>
            """
        #expect(try S3BucketListXMLParser().parse(Data(xml.utf8)).isEmpty)
    }

    private let listing = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <Name>my-bucket</Name>
          <Prefix>logs/</Prefix>
          <KeyCount>3</KeyCount>
          <MaxKeys>1000</MaxKeys>
          <Delimiter>/</Delimiter>
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken>1ueGcxLPRx1Tr</NextContinuationToken>
          <Contents>
            <Key>logs/app.log</Key>
            <LastModified>2026-07-13T21:36:00.000Z</LastModified>
            <ETag>&quot;0x8DEE126C27919F8&quot;</ETag>
            <Size>66560</Size>
            <StorageClass>STANDARD</StorageClass>
          </Contents>
          <Contents>
            <Key>logs/archive.tar.gz</Key>
            <LastModified>2026-07-14T10:00:00.000Z</LastModified>
            <Size>1048576</Size>
            <StorageClass>GLACIER</StorageClass>
          </Contents>
          <CommonPrefixes><Prefix>logs/2026/</Prefix></CommonPrefixes>
          <CommonPrefixes><Prefix>logs/2025/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """

    @Test("Parses objects, sizes, tiers, and dates")
    func parsesObjects() throws {
        let page = try S3ObjectListXMLParser().parse(Data(listing.utf8))
        let objects = page.objects.filter { !$0.isPrefix }
        #expect(objects.map(\.key) == ["logs/app.log", "logs/archive.tar.gz"])
        #expect(objects.first?.size == 66560)
        #expect(objects.first?.storageClass == "STANDARD")
        #expect(objects.first?.etag == "\"0x8DEE126C27919F8\"")
        #expect(objects.last?.storageClass == "GLACIER")
        #expect(objects.first?.lastModified == ISO8601DateFormatter().date(from: "2026-07-13T21:36:00Z"))
    }

    /// `CommonPrefixes` is what makes S3's flat keyspace browsable — without these the
    /// browser would show every key at every depth in one list.
    @Test("Common prefixes become folders")
    func commonPrefixesBecomeFolders() throws {
        let page = try S3ObjectListXMLParser().parse(Data(listing.utf8))
        let prefixes = page.objects.filter(\.isPrefix)
        #expect(prefixes.map(\.key) == ["logs/2026/", "logs/2025/"])
        #expect(prefixes.allSatisfy { $0.size == 0 })
    }

    /// Paging state has to survive parsing or a folder with more than 1000 keys is
    /// silently cut off.
    @Test("Truncation and the continuation token are carried through")
    func carriesPagingState() throws {
        let page = try S3ObjectListXMLParser().parse(Data(listing.utf8))
        #expect(page.isTruncated)
        #expect(page.continuationToken == "1ueGcxLPRx1Tr")
    }

    @Test("A complete listing reports no continuation")
    func untruncatedListing() throws {
        let xml = """
            <ListBucketResult>
              <IsTruncated>false</IsTruncated>
              <Contents><Key>a.txt</Key><Size>1</Size></Contents>
            </ListBucketResult>
            """
        let page = try S3ObjectListXMLParser().parse(Data(xml.utf8))
        #expect(page.isTruncated == false)
        #expect(page.continuationToken == nil)
        #expect(page.objects.count == 1)
    }

    /// A zero-byte key ending in "/" is the placeholder the console creates for an
    /// empty folder. Listing it as a file would show a 0-byte object next to the folder
    /// it represents.
    @Test("Zero-byte folder placeholder keys are not listed as objects")
    func folderPlaceholdersSkipped() throws {
        let xml = """
            <ListBucketResult>
              <IsTruncated>false</IsTruncated>
              <Contents><Key>logs/</Key><Size>0</Size></Contents>
              <Contents><Key>logs/real.txt</Key><Size>10</Size></Contents>
            </ListBucketResult>
            """
        let page = try S3ObjectListXMLParser().parse(Data(xml.utf8))
        #expect(page.objects.map(\.key) == ["logs/real.txt"])
    }

    @Test("Handles an empty listing")
    func emptyListing() throws {
        let xml = "<ListBucketResult><IsTruncated>false</IsTruncated><KeyCount>0</KeyCount></ListBucketResult>"
        #expect(try S3ObjectListXMLParser().parse(Data(xml.utf8)).objects.isEmpty)
    }

    @Test("Malformed XML throws rather than returning nothing")
    func malformedXMLThrows() {
        #expect(throws: (any Error).self) {
            _ = try S3ObjectListXMLParser().parse(Data("<ListBucketResult><Contents>".utf8))
        }
    }

    @Test("Extracts error codes and messages")
    func extractsErrorFields() {
        let body = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Error>
              <Code>NoSuchBucket</Code>
              <Message>The specified bucket does not exist</Message>
              <BucketName>nope</BucketName>
            </Error>
            """
        #expect(S3ErrorXMLParser.code(in: body) == "NoSuchBucket")
        #expect(S3ErrorXMLParser.message(in: body) == "The specified bucket does not exist")
        #expect(S3ErrorXMLParser.code(in: "not xml") == nil)
        #expect(S3ErrorXMLParser.element("UploadId", in: "<UploadId>abc123</UploadId>") == "abc123")
        #expect(S3ErrorXMLParser.element("UploadId", in: "<UploadId></UploadId>") == nil)
    }
}

@Suite("S3 response handling")
struct S3ResponseHandlingTests {

    private func response(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://b.s3.amazonaws.com/k")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    /// A bucket in another region answers 301 with the correct one in a header. Treating
    /// that as a generic failure would strand the user on a bucket they can see in
    /// ListBuckets but never open.
    @Test("A redirect is reported as a wrong-region error carrying the right region")
    func wrongRegionIsRecoverable() throws {
        let error = S3RESTClient.error(
            status: 301,
            body: "<Error><Code>PermanentRedirect</Code></Error>",
            bucket: "my-bucket",
            response: response(status: 301, headers: ["x-amz-bucket-region": "eu-west-1"])
        )
        guard case let S3Error.wrongRegion(bucket, correctRegion) = error else {
            Issue.record("expected wrongRegion, got \(error)")
            return
        }
        #expect(bucket == "my-bucket")
        #expect(correctRegion == "eu-west-1")
    }

    /// A signature mismatch caused by signing for the wrong region comes back as a 400,
    /// not a redirect — and it means the same thing.
    @Test("A malformed-authorization 400 is also a region problem")
    func malformedAuthorizationIsRegion() {
        let error = S3RESTClient.error(
            status: 400,
            body: "<Error><Code>AuthorizationHeaderMalformed</Code></Error>",
            bucket: "b",
            response: response(status: 400, headers: ["x-amz-bucket-region": "us-west-1"])
        )
        guard case S3Error.wrongRegion = error else {
            Issue.record("expected wrongRegion, got \(error)")
            return
        }
    }

    @Test("Auth failures map to unauthorized, permissions to forbidden")
    func authAndPermissionMapping() {
        let expired = S3RESTClient.error(
            status: 400,
            body: "<Error><Code>ExpiredToken</Code></Error>",
            bucket: "b",
            response: response(status: 400)
        )
        #expect(expired as? StorageProviderError == .unauthorized)

        let denied = S3RESTClient.error(
            status: 403,
            body: "<Error><Code>AccessDenied</Code></Error>",
            bucket: "b",
            response: response(status: 403)
        )
        #expect(denied as? StorageProviderError == .dataPlaneForbidden(account: "b"))
    }

    @Test("A missing bucket is named in its own error")
    func missingBucket() {
        let error = S3RESTClient.error(
            status: 404,
            body: "<Error><Code>NoSuchBucket</Code></Error>",
            bucket: "gone",
            response: response(status: 404)
        )
        guard case let S3Error.noSuchBucket(name) = error else {
            Issue.record("expected noSuchBucket, got \(error)")
            return
        }
        #expect(name == "gone")
    }

    @Test("Anything else keeps its status, code, and message")
    func genericErrorRetainsDetail() {
        let error = S3RESTClient.error(
            status: 500,
            body: "<Error><Code>InternalError</Code><Message>We encountered an internal error</Message></Error>",
            bucket: "b",
            response: response(status: 500)
        )
        guard case let S3Error.httpError(status, code, message) = error else {
            Issue.record("expected httpError, got \(error)")
            return
        }
        #expect(status == 500)
        #expect(code == "InternalError")
        #expect(message == "We encountered an internal error")
    }

    @Test("Decodes metadata from HEAD headers")
    func decodesHeadMetadata() {
        let metadata = S3RESTClient.metadata(from: response(status: 200, headers: [
            "Content-Length": "66560",
            "Content-Type": "application/vnd.ms-excel",
            "ETag": "\"abc123\"",
            "Last-Modified": "Mon, 13 Jul 2026 21:36:00 GMT",
            "x-amz-storage-class": "GLACIER",
            "x-amz-meta-Owner": "data-team",
            "x-amz-meta-source": "nightly",
        ]))

        #expect(metadata.size == 66560)
        #expect(metadata.contentType == "application/vnd.ms-excel")
        #expect(metadata.etag == "\"abc123\"")
        #expect(metadata.storageClass == "GLACIER")
        #expect(metadata.blobType == nil)
        // Header names are case-insensitive, so custom keys are normalised to lowercase.
        #expect(metadata.custom == ["owner": "data-team", "source": "nightly"])
        #expect(metadata.lastModified == ISO8601DateFormatter().date(from: "2026-07-13T21:36:00Z"))
    }

    /// S3 omits the storage-class header entirely for STANDARD objects, which is most
    /// of them — a nil tier would show as "—" in the inspector for the common case.
    @Test("A missing storage class defaults to STANDARD")
    func missingStorageClassDefaults() {
        #expect(S3RESTClient.metadata(from: response(status: 200)).storageClass == "STANDARD")
    }

    @Test("HTTP dates parse independently of the host locale")
    func httpDateParsing() {
        #expect(S3RESTClient.parseHTTPDate("Mon, 13 Jul 2026 21:36:00 GMT")
            == ISO8601DateFormatter().date(from: "2026-07-13T21:36:00Z"))
        #expect(S3RESTClient.parseHTTPDate("nonsense") == nil)
    }

    // MARK: - Multipart completion

    @Test("Completion XML lists parts in ascending order with quoted ETags")
    func completionXMLOrdering() {
        let xml = S3RESTClient.completionXML(parts: [
            (number: 2, etag: "\"two\""),
            (number: 1, etag: "one"),
        ])
        #expect(xml == "<CompleteMultipartUpload>"
            + "<Part><PartNumber>1</PartNumber><ETag>\"one\"</ETag></Part>"
            + "<Part><PartNumber>2</PartNumber><ETag>\"two\"</ETag></Part>"
            + "</CompleteMultipartUpload>")
    }

    @Test("Completion XML for a single part is well formed")
    func completionXMLSinglePart() {
        #expect(S3RESTClient.completionXML(parts: [(number: 1, etag: "\"a\"")])
            == "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"a\"</ETag></Part></CompleteMultipartUpload>")
    }
}
