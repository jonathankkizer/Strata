import AppKit
import UniformTypeIdentifiers

/// Drag a blob out of Strata and drop it in Finder (or Mail, or a Terminal window)
/// and it downloads to exactly where you dropped it.
///
/// This is the file-*promise* mechanism rather than a plain file URL on the
/// pasteboard, which is the correct Mac idiom for content that does not exist
/// locally yet: the drag starts instantly with the right icon and name, and the
/// bytes are only fetched if and when the user actually drops. The download then
/// runs through the same `TransferQueue` as everything else, so it shows up in the
/// Transfers popover with progress and a cancel button.
final class BlobFilePromiseProvider: NSFilePromiseProvider, @unchecked Sendable {

    /// Everything needed to perform the download later, at drop time. All Sendable —
    /// the promise is read from the file-promise operation queue, not the main actor.
    struct Payload: Sendable {
        let object: StorageObject
        let container: StorageContainer
        let provider: any StorageProvider
        let fileName: String
    }

    let payload: Payload

    init(payload: Payload, fileType: String, delegate: any NSFilePromiseProviderDelegate) {
        self.payload = payload
        super.init()
        self.fileType = fileType
        self.delegate = delegate
    }

    /// Builds the promise for one blob, or nil for a folder — recursive prefix
    /// download is a separate feature, and promising a directory we cannot yet
    /// produce would be worse than not offering the drag at all.
    @MainActor
    static func make(
        for object: StorageObject,
        in container: StorageContainer,
        provider: any StorageProvider
    ) -> BlobFilePromiseProvider? {
        guard !object.isPrefix else { return nil }
        let type = BlobIcon.utType(for: object)
        let payload = Payload(
            object: object,
            container: container,
            provider: provider,
            fileName: DownloadPlanning.fileName(
                forKey: object.key,
                preferredExtension: type.preferredFilenameExtension
            )
        )
        return BlobFilePromiseProvider(
            payload: payload,
            fileType: type.identifier,
            delegate: BlobFilePromiseDelegate.shared
        )
    }
}

/// Fulfils blob file promises by routing them through the shared transfer queue.
/// Stateless, so one shared instance serves every browse surface —
/// `NSFilePromiseProvider.delegate` is a weak reference, which a per-view-controller
/// delegate would have to outlive anyway.
/// `@unchecked Sendable` is honest here: the only stored state is an OperationQueue,
/// which is itself thread-safe, and AppKit calls these methods off the main thread.
final class BlobFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {

    static let shared = BlobFilePromiseDelegate()

    /// AppKit calls `writePromiseTo` on this queue. It must not be the main queue:
    /// the promise machinery can wait on the operation, and the actual work is
    /// handed straight to the transfer queue anyway.
    private let workQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.kizersolutions.strata.file-promise"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider as? BlobFilePromiseProvider)?.payload.fileName ?? "Untitled"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        workQueue
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let promise = filePromiseProvider as? BlobFilePromiseProvider else {
            completionHandler(StorageProviderError.notImplemented)
            return
        }
        // The SDK's completion handler is not declared Sendable, but AppKit is
        // documented to accept it from any thread; box it to cross the hop.
        let handler = UncheckedSendableBox(completionHandler)
        let payload = promise.payload

        // The destination URL is chosen by the drop receiver (Finder has already
        // resolved any name collision), so the file is written exactly there.
        Task { @MainActor in
            TransferQueue.shared.enqueueDownload(
                object: payload.object,
                container: payload.container,
                to: url,
                provider: payload.provider,
                onFinish: { error in handler.value(error) }
            )
        }
    }
}

/// Carries a non-Sendable value across a concurrency boundary where the API
/// contract — but not the type system — guarantees it is safe.
private final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
