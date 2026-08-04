import Testing
import Foundation
@testable import Strata

/// Live tests against real S3. Everything else in the S3 suites runs against fixtures
/// and a stubbed transport, which can prove the parsing and the shape of a request but
/// cannot prove that AWS *accepts* it — a signature is either right or it is a 403, and
/// only S3 can say which.
///
/// Skipped unless the bucket environment variables are set, so CI (which has no
/// credentials) stays green and nobody's first `xcodebuild test` unexpectedly reaches
/// the network. Run with:
///
/// ```
/// STRATA_S3_BUCKET=… STRATA_S3_BUCKET_EU=… STRATA_S3_BUCKET_DOTTED=… \
///   xcodebuild -project Strata.xcodeproj -scheme Strata \
///   -destination 'platform=macOS,arch=arm64' test
/// ```
///
/// Credentials come from the ambient AWS CLI profile — the same path the app uses, so
/// these exercise `AWSCLICredentialProvider` for real rather than a stub.
@Suite("S3 live integration", .enabled(if: S3IntegrationEnvironment.isConfigured))
struct S3IntegrationTests {

    private let environment = S3IntegrationEnvironment()

    /// Objects seeded by hand with the AWS CLI, so these tests read data written by the
    /// reference implementation rather than by the code under test.
    private static let seededPrefix = "logs/"

    private func client(region: String = "us-east-1") -> S3RESTClient {
        S3RESTClient(
            endpoint: S3Endpoint(region: region),
            credentialSource: AWSCLICredentialProvider()
        )
    }

    // MARK: - Reads

    /// The broadest possible smoke test: if SigV4 is wrong in any way, this is a 403.
    @Test("Lists buckets from the real account")
    func listsRealBuckets() async throws {
        let buckets = try await client().listBuckets()
        #expect(buckets.contains { $0.name == environment.bucket })
    }

    @Test("Lists a prefix with folders and files")
    func listsSeededPrefix() async throws {
        let objects = try await client().listAllObjects(
            bucket: environment.bucket,
            prefix: Self.seededPrefix
        )

        let folders = objects.filter(\.isPrefix).map(\.key)
        #expect(folders.contains("logs/2025/"))
        #expect(folders.contains("logs/2026/"))

        let files = objects.filter { !$0.isPrefix }.map(\.key)
        #expect(files.contains("logs/small.txt"))
        // The delimiter must keep nested keys out of this level.
        #expect(files.contains("logs/2026/nested.txt") == false)
    }

    /// Sizes and timestamps have to survive the XML round trip, not just be present.
    @Test("Reads real sizes and modification dates")
    func readsSizesAndDates() async throws {
        let objects = try await client().listAllObjects(
            bucket: environment.bucket,
            prefix: Self.seededPrefix
        )
        let medium = try #require(objects.first { $0.key == "logs/medium.bin" })
        #expect(medium.size == 300_000)
        #expect(medium.storageClass == "STANDARD")
        let modified = try #require(medium.lastModified)
        // Seeded moments ago; a mis-parsed date would land decades away.
        #expect(abs(modified.timeIntervalSinceNow) < 60 * 60 * 24 * 30)
    }

    /// Forces the continuation-token loop with a page size far below the object count.
    /// Against a stub this proved the loop; here it proves S3 accepts the token we echo
    /// back and that nothing is dropped or duplicated across pages.
    @Test("Follows real continuation tokens")
    func followsRealPaging() async throws {
        let paged = try await client().listAllObjects(
            bucket: environment.bucket,
            prefix: Self.seededPrefix,
            maxKeys: 2
        )
        let unpaged = try await client().listAllObjects(
            bucket: environment.bucket,
            prefix: Self.seededPrefix
        )
        #expect(paged.map(\.key).sorted() == unpaged.map(\.key).sorted())
        #expect(paged.count > 2)
        // No duplicates across page boundaries.
        #expect(Set(paged.map(\.key)).count == paged.count)
    }

    /// The key that would catch a path-encoding bug: a space *and* a `+`. If the URL is
    /// built differently from what was signed, S3 answers 403, and if `+` is treated as
    /// a space the key simply isn't found.
    @Test("Handles a key with spaces and a plus sign")
    func handlesAwkwardKey() async throws {
        let metadata = try await client().headObject(
            bucket: environment.bucket,
            key: "logs/a file with spaces+plus.txt"
        )
        #expect(metadata.size == 18)
    }

    @Test("Reads content type and user metadata from a real HEAD")
    func readsRealMetadata() async throws {
        let metadata = try await client().headObject(
            bucket: environment.bucket,
            key: "logs/tagged.txt"
        )
        #expect(metadata.size == 18)
        #expect(metadata.contentType == "text/plain")
        #expect(metadata.custom["owner"] == "data-team")
        #expect(metadata.etag?.isEmpty == false)
        #expect(metadata.storageClass == "STANDARD")
    }

    @Test("Downloads an object with byte progress")
    func downloadsWithProgress() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("strata-s3-download-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        let ticks = ProgressRecorder()
        try await client().downloadObject(
            bucket: environment.bucket,
            key: "logs/medium.bin",
            to: destination
        ) { sent, _ in ticks.record(sent) }

        let data = try Data(contentsOf: destination)
        #expect(data.count == 300_000)
        #expect(ticks.count > 0)
        // Progress must end on the real total, not merely somewhere near it.
        #expect(ticks.last == 300_000)
    }

    // MARK: - Writes

    @Test("Round-trips a single-request upload")
    func roundTripsPutObject() async throws {
        let client = client()
        let key = "strata-integration/put-\(UUID().uuidString).txt"
        let payload = Data("round trip\n".utf8)

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("strata-put-\(UUID().uuidString).txt")
        try payload.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        try await client.putObject(
            bucket: environment.bucket,
            key: key,
            fileURL: source,
            contentType: "text/plain"
        )
        defer { Task { try? await client.deleteObject(bucket: environment.bucket, key: key) } }

        let metadata = try await client.headObject(bucket: environment.bucket, key: key)
        #expect(metadata.size == Int64(payload.count))
        #expect(metadata.contentType == "text/plain")

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("strata-put-back-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: destination) }
        try await client.downloadObject(bucket: environment.bucket, key: key, to: destination)
        #expect(try Data(contentsOf: destination) == payload)
    }

    /// The differentiator's premise, checked against reality rather than asserted.
    ///
    /// A multipart-committed object's ETag ends in `-<partCount>`, which is S3's own
    /// observable record of *how* the object was written. That is the same distinction
    /// that decides whether the emitted event is `s3:ObjectCreated:Put` or
    /// `s3:ObjectCreated:CompleteMultipartUpload` — so this confirms the prediction
    /// describes what actually happens, not just what the code intends.
    @Test("A multipart upload really commits as multipart")
    func multipartCommitsAsMultipart() async throws {
        let client = client()
        let key = "strata-integration/multipart-\(UUID().uuidString).bin"

        // 12 MiB against the default 8 MiB part size gives two parts, and keeps the
        // final part above S3's 5 MiB minimum for all but the last.
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("strata-multipart-\(UUID().uuidString).bin")
        try Data(repeating: 0x5A, count: 12 * 1024 * 1024).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let ticks = ProgressRecorder()
        try await client.putObjectMultipart(
            bucket: environment.bucket,
            key: key,
            fileURL: source,
            contentType: "application/octet-stream"
        ) { sent, _ in ticks.record(sent) }
        defer { Task { try? await client.deleteObject(bucket: environment.bucket, key: key) } }

        let metadata = try await client.headObject(bucket: environment.bucket, key: key)
        #expect(metadata.size == 12 * 1024 * 1024)

        let etag = try #require(metadata.etag)
        #expect(etag.contains("-2"), "expected a 2-part multipart ETag, got \(etag)")

        // Snapshotted once: a trailing callback can land between two reads, which
        // makes a failure report two values that look identical.
        let (finalBytes, monotonic) = ticks.snapshot()
        // Unwrapped rather than compared as an Optional, so a failure reports a plain
        // number instead of an optional that renders identically to the expected value.
        let observed = try #require(finalBytes)
        // Progress has to climb across parts rather than restarting at each one.
        #expect(observed == Int64(12 * 1024 * 1024), "final progress tick was \(observed)")
        #expect(monotonic)
    }

    @Test("Deleting is idempotent")
    func deleteIsIdempotent() async throws {
        let client = client()
        let key = "strata-integration/delete-\(UUID().uuidString).txt"
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("strata-del-\(UUID().uuidString).txt")
        try Data("bye\n".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        try await client.putObject(bucket: environment.bucket, key: key, fileURL: source, contentType: nil)
        try await client.deleteObject(bucket: environment.bucket, key: key)
        // A second delete of a key that is already gone must not throw.
        try await client.deleteObject(bucket: environment.bucket, key: key)
    }

    // MARK: - Through the provider

    /// Everything above drives `S3RESTClient` directly. These go through `S3Provider`,
    /// which is what the browse surface actually holds — so they cover the wiring the
    /// UI depends on, not just the transport underneath it.
    private func liveProvider(region: String = "us-east-1") -> S3Provider {
        S3Provider(profile: AWSAuth.defaultProfileName, region: region)
    }

    @Test("The provider lists buckets and objects")
    func providerListsThroughTheProtocol() async throws {
        let provider = liveProvider()
        #expect(try await provider.listContainers().contains { $0.name == environment.bucket })

        let objects = try await provider.listObjects(
            in: StorageContainer(name: environment.bucket),
            prefix: Self.seededPrefix
        )
        #expect(objects.contains { $0.key == "logs/small.txt" })
        #expect(objects.contains { $0.isPrefix && $0.key == "logs/2026/" })
    }

    /// Stage 4's whole point: a bucket in a region the profile isn't configured for
    /// opens anyway. The provider takes S3's correction and retries, so the user never
    /// sees a region error for a bucket they can see in the sidebar.
    @Test("The provider opens a bucket in another region without being told")
    func providerCrossesRegionsTransparently() async throws {
        // Configured for us-east-1; the bucket lives in eu-west-1.
        let provider = liveProvider(region: "us-east-1")
        let objects = try await provider.listObjects(
            in: StorageContainer(name: environment.euBucket),
            prefix: ""
        )
        #expect(objects.isEmpty)   // the eu bucket is empty, but reaching it is the point
    }

    @Test("The provider reads metadata through the same path")
    func providerFetchesMetadata() async throws {
        let metadata = try await liveProvider().fetchMetadata(
            for: StorageObject(key: "logs/tagged.txt"),
            in: StorageContainer(name: environment.bucket)
        )
        #expect(metadata.contentType == "text/plain")
        #expect(metadata.custom["owner"] == "data-team")
    }

    /// The upload path the transfer queue calls, with the plan deciding the operation —
    /// so a prediction shown in the UI and the write that follows it stay in step.
    @Test("The provider uploads and downloads through a plan")
    func providerRoundTripsWithPlan() async throws {
        let provider = liveProvider()
        let container = StorageContainer(name: environment.bucket)
        let key = "strata-integration/provider-\(UUID().uuidString).txt"
        let payload = Data("via the provider\n".utf8)

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("strata-provider-\(UUID().uuidString).txt")
        try payload.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let plan = UploadPlan(byteCount: Int64(payload.count), target: .s3)
        #expect(plan.usesMultipleRequests == false)

        try await provider.upload(
            from: source,
            toKey: key,
            in: container,
            contentType: "text/plain",
            plan: plan,
            onProgress: nil
        )

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("strata-provider-back-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: destination) }
        try await provider.download(fromKey: key, in: container, to: destination, onProgress: nil)
        #expect(try Data(contentsOf: destination) == payload)

        // Cleaned up through the client, since deletion isn't on the provider protocol yet.
        try await S3RESTClient(
            endpoint: S3Endpoint(region: "us-east-1"),
            credentialSource: AWSCLICredentialProvider()
        ).deleteObject(bucket: environment.bucket, key: key)
    }

    // MARK: - Addressing and regions

    /// The case a local S3-compatible server cannot reproduce: a bucket addressed with
    /// the wrong region. `S3Error.wrongRegion` exists to carry the right one so the
    /// caller can retry instead of stranding the user on a bucket they can see in
    /// ListBuckets but cannot open.
    @Test("A bucket in another region reports where it really lives")
    func wrongRegionIsReported() async throws {
        do {
            _ = try await client(region: "us-east-1").listObjectsPage(
                bucket: environment.euBucket,
                prefix: ""
            )
            Issue.record("expected a wrong-region error for a eu-west-1 bucket signed us-east-1")
        } catch let S3Error.wrongRegion(_, correctRegion) {
            #expect(correctRegion == "eu-west-1")
        } catch {
            Issue.record("got \(error) instead of .wrongRegion")
        }
    }

    @Test("Resolves a bucket's real region")
    func resolvesBucketRegion() async throws {
        let euRegion = try await client().bucketRegion(bucket: environment.euBucket)
        #expect(euRegion == "eu-west-1", "resolved \(euRegion)")
        let useRegion = try await client().bucketRegion(bucket: environment.bucket)
        #expect(useRegion == "us-east-1", "resolved \(useRegion)")
    }

    @Test("Reaches the same bucket once signed for the right region")
    func correctRegionSucceeds() async throws {
        let page = try await client(region: "eu-west-1").listObjectsPage(
            bucket: environment.euBucket,
            prefix: ""
        )
        #expect(page.isTruncated == false)
    }

    /// A dotted bucket name cannot be a hostname label, so this only works if the
    /// path-style fallback fires. Against a virtual-hosted URL it fails in TLS, which
    /// looks like a network fault rather than an addressing bug.
    @Test("Reaches a dotted bucket via the path-style fallback")
    func dottedBucketUsesPathStyle() async throws {
        let page = try await client().listObjectsPage(bucket: environment.dottedBucket, prefix: "")
        #expect(page.objects.isEmpty)
    }

    /// Reading a bucket that isn't there must be a clear, named error rather than a
    /// generic HTTP failure.
    @Test("A missing bucket is reported as missing")
    func missingBucketIsNamed() async throws {
        let name = "strata-does-not-exist-\(UUID().uuidString.lowercased().prefix(12))"
        do {
            _ = try await client().listObjectsPage(bucket: String(name), prefix: "")
            Issue.record("expected a failure for a nonexistent bucket")
        } catch let S3Error.noSuchBucket(reported) {
            #expect(reported == String(name))
        } catch let S3Error.httpError(status, code, _) {
            // Acceptable too: some paths surface it as a plain 404.
            #expect(status == 404)
            #expect(code == "NoSuchBucket")
        }
    }
}

// MARK: - Environment

/// Bucket names for the live suite, from the environment so nothing account-specific is
/// ever committed.
struct S3IntegrationEnvironment {
    let bucket: String
    let euBucket: String
    let dottedBucket: String

    init() {
        let environment = ProcessInfo.processInfo.environment
        bucket = environment["STRATA_S3_BUCKET"] ?? ""
        euBucket = environment["STRATA_S3_BUCKET_EU"] ?? ""
        dottedBucket = environment["STRATA_S3_BUCKET_DOTTED"] ?? ""
    }

    static var isConfigured: Bool {
        let environment = ProcessInfo.processInfo.environment
        return ["STRATA_S3_BUCKET", "STRATA_S3_BUCKET_EU", "STRATA_S3_BUCKET_DOTTED"]
            .allSatisfy { !(environment[$0] ?? "").isEmpty }
    }
}

/// Collects progress callbacks, which arrive on a background queue.
final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []

    func record(_ value: Int64) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }

    var last: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }

    /// Byte counts must never go backwards — a multipart upload that reset its offset
    /// per part would show the progress bar jumping back at every boundary.
    var isMonotonic: Bool {
        lock.lock()
        defer { lock.unlock() }
        return zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }
    }

    /// Final byte count and monotonicity read under one lock, so an assertion and its
    /// failure message can't disagree because a callback landed in between.
    func snapshot() -> (last: Int64?, isMonotonic: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (values.last, zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }
}
