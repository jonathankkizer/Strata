import AppKit
import UniformTypeIdentifiers

/// Resolves the real macOS document/folder icon for a stored object, so the
/// browser shows the same icons Finder does (the actual blue folder, a Markdown
/// document icon, etc.) rather than tinted SF Symbols. Blob previews of contents
/// still await a download path; this is the type icon, same as Finder's list view.
enum BlobIcon {

    /// The system folder icon, for places that stand for a folder without having a
    /// `StorageObject` in hand — a saved place, for instance.
    static var folder: NSImage {
        NSWorkspace.shared.icon(for: .folder)
    }

    /// The Finder icon for an object. Folders get the system folder icon; blobs get
    /// the icon for their content type (or a generic document when unknown).
    static func image(for object: StorageObject) -> NSImage {
        if object.isPrefix {
            return folder
        }
        return NSWorkspace.shared.icon(for: utType(for: object))
    }

    /// The best UTType for a blob: its MIME content type if known, else the
    /// filename extension, else generic data.
    static func utType(for object: StorageObject) -> UTType {
        if let mime = object.contentType, let type = UTType(mimeType: mime) {
            return type
        }
        let ext = (object.key as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return type
        }
        return .data
    }
}
