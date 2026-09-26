import Foundation

/// What an interrupted upload has already put on the service, so Retry can carry on
/// from there instead of sending every byte again.
///
/// One per upload in the Transfers list, kept across its retries (not across
/// launches). Filled in by the REST clients as blocks and parts land; thread-safe
/// because those callbacks come from wherever the upload is running.
///
/// Resuming is only safe while the local file is the one that was being sent. A
/// fingerprint (size and modification date) is taken at the first attempt, and any
/// change to it — or to the chunk size — throws away what was recorded.
final class UploadResumeState: @unchecked Sendable {

    private let lock = NSLock()
    private var fingerprint: FileFingerprint?
    private var chunkSize: Int?

    /// Azure: a random tag inside every block ID. Uncommitted blocks from someone
    /// else's abandoned upload to the same blob can sit on the service under IDs like
    /// ours; the tag keeps them from ever being mistaken for — and committed as — ours.
    private var blockTag = UploadResumeState.newTag()
    private var completedBlocks = Set<Int>()

    /// S3: the multipart upload in progress, and the parts it has.
    private var multipartUploadID: String?
    private var completedParts: [Int: String] = [:]

    init() {}

    /// Checks the file and chunk size against what was recorded, starting over if
    /// either changed. Returns true when there is something to resume.
    @discardableResult
    func prepare(for fileURL: URL, chunkSize: Int) -> Bool {
        let current = FileFingerprint(fileURL)
        return lock.withLock {
            if current == nil || fingerprint != current || self.chunkSize != chunkSize {
                resetLocked()
                fingerprint = current
                self.chunkSize = chunkSize
                return false
            }
            return !completedBlocks.isEmpty || !completedParts.isEmpty
        }
    }

    /// Forgets everything: after a successful commit, or when the service says what
    /// was recorded is gone.
    func reset() {
        lock.withLock { resetLocked() }
    }

    private func resetLocked() {
        fingerprint = nil
        chunkSize = nil
        blockTag = Self.newTag()
        completedBlocks = []
        multipartUploadID = nil
        completedParts = [:]
    }

    // MARK: Azure blocks

    /// The block ID for block `index`: base64 of a fixed-length string, since Azure
    /// requires every ID in a blob to be the same length.
    func blockID(_ index: Int) -> String {
        let tag = lock.withLock { blockTag }
        return Data(String(format: "%@-%08d", tag, index).utf8).base64EncodedString()
    }

    func hasBlock(_ index: Int) -> Bool { lock.withLock { completedBlocks.contains(index) } }
    func recordBlock(_ index: Int) { _ = lock.withLock { completedBlocks.insert(index) } }

    // MARK: S3 parts

    var uploadID: String? {
        get { lock.withLock { multipartUploadID } }
        set { lock.withLock { multipartUploadID = newValue } }
    }

    func etag(forPart number: Int) -> String? { lock.withLock { completedParts[number] } }
    func recordPart(_ number: Int, etag: String) { lock.withLock { completedParts[number] = etag } }

    private static func newTag() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }
}

/// A download's URLSession resume data, kept across attempts so a retry can pick up
/// where the connection dropped.
final class DownloadResumeState: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    init() {}

    var resumeData: Data? {
        get { lock.withLock { data } }
        set { lock.withLock { data = newValue } }
    }
}

/// A resumed download was refused — its signature or token has expired by now, most
/// likely. Callers answer it by downloading afresh.
struct DownloadResumeRejected: Error {}

/// Enough about a file to tell whether it changed since an upload began — and the
/// place to read an upload's size from, for the same reason as below: a stale size
/// would count too few blocks or parts and commit a truncated object.
struct FileFingerprint: Equatable, Sendable {
    let size: Int
    let modified: Date

    /// Read from the file system every time. `URL.resourceValues` caches on the URL
    /// instance, and a transfer keeps the same URL across retries — so a file edited
    /// between attempts would still look unchanged, and blocks of the old contents
    /// would be committed alongside the new.
    init?(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        self.size = size
        self.modified = modified
    }
}
