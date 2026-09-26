import AppKit
import QuickLookUI

/// One blob, as far as Quick Look is concerned.
final class BlobPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        self.previewItemURL = url
        self.previewItemTitle = title
        super.init()
    }
}

/// Drives the shared Quick Look panel for the browse surfaces.
///
/// Space previews the selection, exactly as it does in the Finder. Because a blob is
/// not a local file, previewing means fetching it into the preview cache first — a
/// second preview of the same blob is instant, and a blob that changed on the server
/// re-fetches (see `PreviewCache`). Arrow keys keep working while the panel is up, so
/// you can walk a listing and watch the preview follow.
@MainActor
final class QuickLookController: NSObject {

    /// The screen rect of the row being previewed, for the panel's zoom animation.
    var sourceFrameProvider: (() -> NSRect?)?
    /// Forwards a key event back to the browse surface underneath the panel.
    var keyForwarder: ((NSEvent) -> Void)?

    private var item: BlobPreviewItem?
    private var fetchTask: Task<Void, Never>?
    /// Identifies the in-flight request, so a superseded fetch can't install its
    /// result over a newer one.
    private var fetchToken = 0

    /// Whether the shared panel is currently showing our content.
    var isPreviewing: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    // MARK: - Presenting

    /// Prepares `object` and shows the panel once the bytes are on disk. Called again
    /// as the selection moves, which just swaps the panel's content.
    func preview(
        object: StorageObject,
        container: StorageContainer,
        provider: any StorageProvider,
        account: String,
        openingPanel: Bool
    ) {
        guard PreviewCache.isPreviewable(object) else {
            if openingPanel { presentTooLarge(object) }
            return
        }

        fetchTask?.cancel()
        fetchToken += 1
        let token = fetchToken

        let destination = PreviewCache.directory
            .appendingPathComponent(PreviewCache.relativePath(
                account: account, container: container.name, object: object
            ))
        let title = DownloadPlanning.fileName(forKey: object.key)

        // A cache hit is the common case once you've looked at something; show it
        // without a round trip so Space feels instant.
        if FileManager.default.fileExists(atPath: destination.path) {
            PreviewCache.markUsed(destination)
            install(BlobPreviewItem(url: destination, title: title), openingPanel: openingPanel)
            return
        }

        fetchTask = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try await provider.download(fromKey: object.key, in: container, to: destination, onProgress: nil)
            } catch {
                // Arrowing through a list with the panel open cancels each fetch as the
                // next starts; that's not a failure worth a sound.
                guard let self, token == self.fetchToken, !Task.isCancelled else { return }
                // A failed preview is not worth an alert: the row is still selected,
                // and the inspector already reports what went wrong with the object.
                NSSound.beep()
                return
            }
            guard let self, token == self.fetchToken, !Task.isCancelled else { return }
            self.install(BlobPreviewItem(url: destination, title: title), openingPanel: openingPanel)
        }
    }

    private func install(_ newItem: BlobPreviewItem, openingPanel: Bool) {
        item = newItem
        guard QLPreviewPanel.sharedPreviewPanelExists() || openingPanel,
              let panel = QLPreviewPanel.shared() else { return }
        if openingPanel, !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
        // The panel may already be showing the previous selection.
        if panel.isVisible {
            panel.reloadData()
        }
    }

    /// Closes the panel and drops any in-flight fetch.
    func close() {
        fetchTask?.cancel()
        fetchTask = nil
        fetchToken += 1
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
    }

    /// Nothing selectable is in view any more (navigated away, deselected).
    func clear() {
        fetchTask?.cancel()
        fetchTask = nil
        fetchToken += 1
        item = nil
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    private func presentTooLarge(_ object: StorageObject) {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let alert = NSAlert()
        alert.messageText = "\u{201C}\(DownloadPlanning.fileName(forKey: object.key))\u{201D} is too large to preview."
        alert.informativeText = "Quick Look fetches a copy of the blob, and this one is "
            + "\(formatter.string(fromByteCount: object.size)) — over the "
            + "\(formatter.string(fromByteCount: PreviewCache.maximumPreviewBytes)) preview limit. "
            + "Download it instead to open it in an app."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - QLPreviewPanelDataSource

// `@preconcurrency`: the panel's `dataSource`/`delegate` are nonisolated properties,
// so a MainActor-isolated conformance can't be stored in them without it. Quick Look
// only ever calls these from the main thread — it is driving a window.
extension QuickLookController: @preconcurrency QLPreviewPanelDataSource {

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        item == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        item
    }
}

// MARK: - QLPreviewPanelDelegate

extension QuickLookController: @preconcurrency QLPreviewPanelDelegate {

    /// Zoom the panel out of the row it came from, the way Finder does.
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        sourceFrameProvider?() ?? .zero
    }

    /// Keep arrow keys driving the list underneath so the preview follows the
    /// selection — the whole point of Quick Look in a file browser.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        let arrows: Set<String> = [
            String(UnicodeScalar(NSUpArrowFunctionKey)!),
            String(UnicodeScalar(NSDownArrowFunctionKey)!),
        ]
        guard let characters = event.charactersIgnoringModifiers, arrows.contains(characters) else {
            return false
        }
        keyForwarder?(event)
        return true
    }
}
