import Foundation
import Testing
@testable import Strata

@Suite("PreviewCache path policy")
struct PreviewCachePathTests {

    private func object(
        key: String,
        size: Int64 = 1024,
        etag: String? = "\"abc123\"",
        isPrefix: Bool = false
    ) -> StorageObject {
        StorageObject(key: key, size: size, etag: etag, isPrefix: isPrefix)
    }

    @Test("The cached file keeps the blob's real name, so Quick Look picks the right previewer")
    func keepsFileName() {
        let path = PreviewCache.relativePath(
            account: "acct", container: "data", object: object(key: "raw/2026/report.csv")
        )
        #expect(path.hasSuffix("/report.csv"))
    }

    @Test("A key's slashes never leak into the cache path beyond the one separator")
    func flattensKeyIntoOneComponent() {
        let path = PreviewCache.relativePath(
            account: "acct", container: "data", object: object(key: "a/b/c/d/e/report.csv")
        )
        #expect(path.split(separator: "/").count == 2)
    }

    @Test("The same blob resolves to the same path")
    func stable() {
        let blob = object(key: "raw/report.csv")
        let first = PreviewCache.relativePath(account: "acct", container: "data", object: blob)
        let second = PreviewCache.relativePath(account: "acct", container: "data", object: blob)
        #expect(first == second)
    }

    @Test("Same-named blobs in different containers or accounts do not collide")
    func noCrossContainerCollision() {
        let blob = object(key: "report.csv")
        let a = PreviewCache.relativePath(account: "acct", container: "one", object: blob)
        let b = PreviewCache.relativePath(account: "acct", container: "two", object: blob)
        let c = PreviewCache.relativePath(account: "other", container: "one", object: blob)
        #expect(a != b)
        #expect(a != c)
    }

    @Test("A changed etag busts the cache, so an updated blob re-fetches")
    func etagBustsCache() {
        let before = PreviewCache.relativePath(
            account: "acct", container: "data", object: object(key: "report.csv", etag: "\"v1\"")
        )
        let after = PreviewCache.relativePath(
            account: "acct", container: "data", object: object(key: "report.csv", etag: "\"v2\"")
        )
        #expect(before != after)
    }

    @Test("Without an etag, size stands in as the version")
    func sizeFallbackWhenNoEtag() {
        let small = PreviewCache.relativePath(
            account: "acct", container: "data", object: object(key: "report.csv", size: 10, etag: nil)
        )
        let grown = PreviewCache.relativePath(
            account: "acct", container: "data", object: object(key: "report.csv", size: 20, etag: nil)
        )
        #expect(small != grown)
    }
}

@Suite("PreviewCache.isPreviewable")
struct PreviewCachePreviewableTests {

    @Test("An ordinary blob is previewable")
    func ordinaryBlob() {
        #expect(PreviewCache.isPreviewable(StorageObject(key: "report.csv", size: 4096)))
    }

    @Test("A folder is never previewable")
    func folder() {
        #expect(!PreviewCache.isPreviewable(StorageObject(key: "raw/", isPrefix: true)))
    }

    @Test("A blob at the size limit is allowed; one byte over is not")
    func sizeBoundary() {
        let limit = PreviewCache.maximumPreviewBytes
        #expect(PreviewCache.isPreviewable(StorageObject(key: "big.bin", size: limit)))
        #expect(!PreviewCache.isPreviewable(StorageObject(key: "big.bin", size: limit + 1)))
    }

    @Test("A zero-byte blob is still previewable")
    func emptyBlob() {
        #expect(PreviewCache.isPreviewable(StorageObject(key: "empty.txt", size: 0)))
    }
}
