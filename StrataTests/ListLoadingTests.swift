import Testing
import AppKit
@testable import Strata

/// Drives the real list view controller against a provider whose pages arrive when the
/// test says so. TODO.md U1 and R7.
@Suite("List loading", .serialized)
@MainActor
struct ListLoadingTests {

    private func makeList(_ provider: GatedProvider) -> ObjectListViewController {
        let list = ObjectListViewController()
        list.loadViewIfNeeded()
        list.provider = provider
        return list
    }

    private func blob(_ key: String) -> StorageObject { StorageObject(key: key, size: 1) }

    /// Waits for the main actor to finish handling whatever the provider just released.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("Rows appear page by page, merged into order")
    func streams() async {
        let provider = GatedProvider()
        let list = makeList(provider)
        list.location = BrowserLocation(container: "c", prefix: "")

        await provider.release(page: [blob("b"), blob("d")])
        await settle { list.displayedObjects.count == 2 }
        #expect(list.displayedObjects.map(\.key) == ["b", "d"], "got \(list.displayedObjects.map(\.key))")

        await provider.release(page: [blob("a"), blob("c")])
        await provider.finish()
        await settle { list.displayedObjects.count == 4 }
        #expect(list.displayedObjects.map(\.key) == ["a", "b", "c", "d"])
    }

    /// ⌘R used to empty the table, losing the selection and blanking the view.
    @Test("Refreshing keeps the rows and selection until the new listing is in")
    func refreshKeepsRows() async {
        let provider = GatedProvider()
        let list = makeList(provider)
        list.location = BrowserLocation(container: "c", prefix: "")
        await provider.release(page: [blob("a"), blob("b")])
        await provider.finish()
        await settle { list.displayedObjects.count == 2 }
        list.select(keys: ["b"])

        list.reload()
        // Mid-refresh: nothing has changed on screen.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(list.displayedObjects.map(\.key) == ["a", "b"])
        #expect(list.selectedObjects().map(\.key) == ["b"])

        await provider.release(page: [blob("0"), blob("a"), blob("b")])
        await provider.finish()
        await settle { list.displayedObjects.count == 3 }
        #expect(list.displayedObjects.map(\.key) == ["0", "a", "b"])
        #expect(list.selectedObjects().map(\.key) == ["b"])
    }

    @Test("Navigating away cancels the listing still in flight")
    func cancelsSuperseded() async {
        let provider = GatedProvider()
        let list = makeList(provider)
        list.location = BrowserLocation(container: "c", prefix: "slow/")
        await settle { provider.started >= 1 }
        list.location = BrowserLocation(container: "c", prefix: "fast/")
        await settle { provider.cancelled >= 1 }
        #expect(provider.cancelled == 1)
    }
}

/// Each listing waits for the test to hand it pages, then to finish it.
final class GatedProvider: StorageProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var pageContinuation: AsyncStream<[StorageObject]?>.Continuation?
    private var startedCount = 0
    private var cancelledCount = 0

    var started: Int { lock.withLock { startedCount } }
    var cancelled: Int { lock.withLock { cancelledCount } }

    var kind: ProviderKind { .azureBlob }
    var displayName: String { "gated" }

    func release(page: [StorageObject]) async {
        await waitForListing()
        _ = lock.withLock { pageContinuation?.yield(page) }
    }

    func finish() async {
        await waitForListing()
        _ = lock.withLock { pageContinuation?.yield(nil) }
    }

    private func waitForListing() async {
        for _ in 0..<200 where lock.withLock({ pageContinuation == nil }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func listObjects(in container: StorageContainer, prefix: String, onPage: @escaping @Sendable ([StorageObject]) async -> Void) async throws {
        let (stream, continuation) = AsyncStream<[StorageObject]?>.makeStream()
        lock.withLock {
            pageContinuation = continuation
            startedCount += 1
        }
        defer { lock.withLock { pageContinuation = nil } }
        for await page in stream {
            guard let page else { return }
            await onPage(page)
        }
        lock.withLock { cancelledCount += 1 }
        throw CancellationError()
    }

    func listObjects(in container: StorageContainer, prefix: String) async throws -> [StorageObject] {
        let all = Accumulator()
        try await listObjects(in: container, prefix: prefix) { all.append($0) }
        return all.objects
    }

    func listContainers() async throws -> [StorageContainer] { [] }
    func fetchMetadata(for object: StorageObject, in container: StorageContainer) async throws -> ObjectMetadata {
        throw CancellationError()
    }
    func objectURL(forKey key: String, in container: StorageContainer) -> URL? { nil }
    func upload(from fileURL: URL, toKey key: String, in container: StorageContainer, contentType: String?, plan: UploadPlan, onProgress: (@Sendable (Int64, Int64) -> Void)?) async throws {}
    func download(fromKey key: String, in container: StorageContainer, to destinationURL: URL, onProgress: (@Sendable (Int64, Int64) -> Void)?) async throws {}
    func delete(key: String, in container: StorageContainer) async throws {}
    func listAllKeys(under prefix: String, in container: StorageContainer) async throws -> [StorageObject] { [] }
    func deletionRecovery(in container: StorageContainer) async -> DeletionRecovery { .unknown }
}

private final class Accumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [StorageObject] = []
    func append(_ page: [StorageObject]) { lock.withLock { collected += page } }
    var objects: [StorageObject] { lock.withLock { collected } }
}
