import Foundation
import UniformTypeIdentifiers

extension StorageObject {

    /// The best type for a blob: its MIME content type if it has a known one, else
    /// its filename extension, else generic data.
    var utType: UTType {
        if let mime = contentType, let type = UTType(mimeType: mime) {
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
