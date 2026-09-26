import CryptoKit
import Foundation

/// Where a blob lands on disk so Quick Look can preview it.
///
/// Quick Look previews files, not byte streams, so a preview means a fetch. Cached
/// copies live under the app's Caches directory — the right place for data the
/// system may reclaim and the user never needs to manage — keyed so that a blob
/// which has changed on the server re-fetches instead of showing a stale preview.
///
/// The path policy is pure and filesystem-free so it can be unit-tested headlessly.
enum PreviewCache {

    /// Blobs above this are not previewed. Quick Look on a multi-gigabyte blob would
    /// mean a silent multi-gigabyte download; the app offers Download instead.
    static let maximumPreviewBytes: Int64 = 64 * 1024 * 1024

    /// The cache-relative path for one object: a content-addressed directory holding
    /// a file with the blob's real name.
    ///
    /// The name matters — Quick Look picks its previewer from the extension, and
    /// shows the file name as the panel title. The directory is a digest so that two
    /// blobs called `data.csv` in different containers cannot collide, and so a key
    /// containing characters the filesystem dislikes never reaches a path component.
    static func relativePath(account: String, container: String, object: StorageObject) -> String {
        // The etag changes on every write, so including it means an updated blob
        // misses the cache and re-fetches. Size and modification date stand in when
        // a provider does not supply one.
        let version = object.etag
            ?? "\(object.size)-\(object.lastModified?.timeIntervalSince1970 ?? 0)"
        let identity = "\(account)\u{0}\(container)\u{0}\(object.key)\u{0}\(version)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        let folder = digest.map { String(format: "%02x", $0) }.joined().prefix(16)

        let fileName = DownloadPlanning.fileName(forKey: object.key)
        return "\(folder)/\(fileName)"
    }

    /// True when the object is small enough to be worth fetching for a preview.
    static func isPreviewable(_ object: StorageObject) -> Bool {
        !object.isPrefix && object.size <= maximumPreviewBytes
    }

    /// How much the cache keeps before the oldest previews go.
    static let sizeLimit: Int64 = 512 * 1024 * 1024

    /// Removes the least recently used previews until the cache is under `limit`.
    /// Each preview lives in its own folder, and a folder's modification date is
    /// bumped whenever it's shown again (`markUsed`), so that date is "last used".
    ///
    /// The Caches directory is the system's to reclaim, but it does so only under
    /// pressure; without this, every version of everything ever previewed stayed.
    static func prune(_ directory: URL = directory, limit: Int64 = sizeLimit, fileManager: FileManager = .default) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let folders = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }

        var entries: [(url: URL, used: Date, bytes: Int64)] = []
        for folder in folders {
            let used = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            var bytes: Int64 = 0
            if let files = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
                for case let file as URL in files {
                    bytes += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
                }
            }
            entries.append((folder, used, bytes))
        }

        var total = entries.reduce(0) { $0 + $1.bytes }
        for entry in entries.sorted(by: { $0.used < $1.used }) where total > limit {
            if (try? fileManager.removeItem(at: entry.url)) != nil {
                total -= entry.bytes
            }
        }
    }

    /// Records that a cached preview was just shown, so pruning keeps it.
    static func markUsed(_ file: URL, fileManager: FileManager = .default) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.deletingLastPathComponent().path)
    }

    /// The root of the preview cache: `~/Library/Caches/<bundle id>/QuickLook`.
    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.kizersolutions.strata"
        return caches.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("QuickLook", isDirectory: true)
    }
}
