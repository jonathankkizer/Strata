import Foundation
import UniformTypeIdentifiers

struct PlannedUpload: Sendable {
    let url: URL
    let key: String
    let plan: UploadPlan
    let contentType: String?
}

/// Expands dropped or chosen URLs into per-file uploads. Regular files map
/// directly; directories are walked recursively with hidden files skipped, each
/// file keyed under the directory's own name. Results are sorted by key so the
/// queue order is deterministic.
enum UploadPlanning {
    nonisolated static func expand(urls: [URL], prefix: String, target: UploadTarget) -> [PlannedUpload] {
        var results: [PlannedUpload] = []

        for url in urls {
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = resourceValues?.isDirectory ?? false

            if isDirectory {
                // Resolve symlinks on both ends before computing relative paths:
                // enumerated URLs can come back resolved (e.g. /private/var) while
                // the dropped URL isn't (/var), which would misalign the paths.
                let basePath = url.resolvingSymlinksInPath().path + "/"
                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for case let fileURL as URL in enumerator {
                    guard let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
                          values.isDirectory != true else { continue }

                    // The key comes from where the file sits in the tree, with only its
                    // directory resolved (for /var vs /private/var). Resolving the file
                    // itself keyed a symlink by its target's path: the link's own name
                    // was lost, and the target was uploaded twice under one key.
                    let sitePath = fileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
                        + "/" + fileURL.lastPathComponent
                    // Files symlinked to outside the dropped tree are skipped.
                    guard sitePath.hasPrefix(basePath),
                          fileURL.resolvingSymlinksInPath().path.hasPrefix(basePath) else { continue }
                    let relativePath = String(sitePath.dropFirst(basePath.count))
                    let key = prefix + url.lastPathComponent + "/" + relativePath
                    let size = values.fileSize.map(Int64.init) ?? 0
                    let contentType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                    results.append(PlannedUpload(
                        url: fileURL,
                        key: key,
                        plan: UploadPlan(byteCount: size, target: target),
                        contentType: contentType
                    ))
                }
            } else {
                let fileValues = try? url.resourceValues(forKeys: [.fileSizeKey])
                let size = fileValues?.fileSize.map(Int64.init) ?? 0
                let contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                results.append(PlannedUpload(
                    url: url,
                    key: prefix + url.lastPathComponent,
                    plan: UploadPlan(byteCount: size, target: target),
                    contentType: contentType
                ))
            }
        }

        return results.sorted { $0.key < $1.key }
    }
}
