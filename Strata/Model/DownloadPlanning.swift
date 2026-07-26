import Foundation

/// Pure planning logic for the download path — deciding what a blob is called on
/// disk and where it lands without colliding with an existing file.
///
/// Deliberately free of AppKit and of any filesystem access (collision checks come
/// in as a closure), so the whole policy is unit-testable headlessly.
enum DownloadPlanning {

    /// The local file name for a blob key: the last path segment, with the storage
    /// separator stripped. Keys are opaque strings that merely *look* hierarchical,
    /// so a key can contain characters that are illegal in a file name — `/` is the
    /// only one HFS+/APFS actually rejects, and it can't survive segment splitting.
    /// A key ending in `/` (a folder marker) yields the last real segment.
    ///
    /// When the key carries no extension but the blob's content type implies one,
    /// it is appended — the same thing Safari does, and what makes the file open in
    /// the right app after a drag to the Desktop. Pass the UTType's
    /// `preferredFilenameExtension` as `preferredExtension`.
    static func fileName(forKey key: String, preferredExtension: String? = nil) -> String {
        let segments = key.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = segments.last, !last.isEmpty else { return "Untitled" }
        // A leading dot would make the download invisible in Finder for a user who
        // never asked for a hidden file; keep the name but don't hide it.
        var name = last.hasPrefix(".") ? "Blob " + String(last) : String(last)
        if (name as NSString).pathExtension.isEmpty,
           let preferredExtension, !preferredExtension.isEmpty {
            name += "." + preferredExtension
        }
        return name
    }

    /// A non-colliding URL for `fileName` in `directory`, following Finder's
    /// disambiguation: `report.csv`, then `report 2.csv`, `report 3.csv`, …
    ///
    /// `exists` is injected so this stays testable; call sites pass
    /// `FileManager.default.fileExists(atPath:)`.
    static func uniqueURL(
        fileName: String,
        in directory: URL,
        exists: (URL) -> Bool
    ) -> URL {
        let candidate = directory.appendingPathComponent(fileName)
        guard exists(candidate) else { return candidate }

        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension

        // Finder starts at 2 and counts up. Bounded so a pathological directory
        // can't spin forever; past the cap we fall back to a UUID suffix.
        for suffix in 2...9999 {
            let name = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            let url = directory.appendingPathComponent(name)
            if !exists(url) { return url }
        }
        let fallback = ext.isEmpty
            ? "\(base) \(UUID().uuidString)"
            : "\(base) \(UUID().uuidString).\(ext)"
        return directory.appendingPathComponent(fallback)
    }

    /// The user's Downloads folder, or their home directory if it can't be resolved.
    /// Used as the default destination, matching Safari and every other Mac app that
    /// downloads without asking.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
}
