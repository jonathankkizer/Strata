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
    nonisolated static func expand(urls: [URL], prefix: String) -> [PlannedUpload] {
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

                    let resolvedPath = fileURL.resolvingSymlinksInPath().path
                    // Files symlinked to outside the dropped tree are skipped.
                    guard resolvedPath.hasPrefix(basePath) else { continue }
                    let relativePath = String(resolvedPath.dropFirst(basePath.count))
                    let key = prefix + url.lastPathComponent + "/" + relativePath
                    let size = values.fileSize.map(Int64.init) ?? 0
                    let contentType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                    results.append(PlannedUpload(
                        url: fileURL,
                        key: key,
                        plan: UploadPlan(byteCount: size, endpoint: .blob),
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
                    plan: UploadPlan(byteCount: size, endpoint: .blob),
                    contentType: contentType
                ))
            }
        }

        return results.sorted { $0.key < $1.key }
    }
}
