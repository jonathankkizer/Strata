import Foundation
import UniformTypeIdentifiers

extension StorageObject {

    /// The best type for a blob: its MIME content type if it has a known one, else
    /// its filename extension, else generic data.
    var utType: UTType { Self.utType(contentType: contentType, key: key) }

    /// The same guess for a content type that may have come from somewhere other than
    /// the listing (a HEAD's, which is more complete).
    ///
    /// A MIME type that only says "bytes" (`application/octet-stream`, what most
    /// uploaders send when they don't know better) is no guess at all, so it doesn't
    /// beat the extension: a `.csv` stored that way is still a CSV, not "data".
    static func utType(contentType: String?, key: String) -> UTType {
        if let mime = contentType, let type = UTType(mimeType: mime), type != .data {
            return type
        }
        let ext = (key as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return type
        }
        return .data
    }

    /// What the Finder would call it in its Kind column — "PDF document", "Folder" —
    /// rather than a MIME type. Sorting by Kind uses the same words, so the column
    /// reads in order.
    var kindDescription: String {
        if isPrefix { return "Folder" }
        return utType.localizedDescription ?? contentType ?? "Document"
    }
}
