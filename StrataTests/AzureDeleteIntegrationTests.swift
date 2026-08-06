import Testing
import Foundation
@testable import Strata

/// Live delete tests against a real Azure Blob account.
///
/// The Azure side has always been checked with throwaway harnesses; delete is the first
/// operation destructive enough to deserve a repeatable one. The account name is never
/// written down here — it comes from the environment, so this file says nothing about
/// whose storage it was pointed at.
///
/// Skipped unless configured, so CI stays green without credentials. Run with:
///
/// ```
/// TEST_RUNNER_STRATA_AZ_ACCOUNT=… TEST_RUNNER_STRATA_AZ_CONTAINER=… \
///   xcodebuild -project Strata.xcodeproj -scheme Strata \
///   -destination 'platform=macOS,arch=arm64' test
/// ```
///
/// `xcodebuild` only forwards variables prefixed `TEST_RUNNER_` into an app-hosted test
/// process — a plain variable silently doesn't arrive and the suite skips while looking
/// like it passed.
///
/// Everything these tests touch is created by them, under a per-run UUID prefix inside
/// `strata-test/`, and removed again. They never read or write anything else.
@Suite("Azure delete live integration", .enabled(if: AzureIntegrationEnvironment.isConfigured))
struct AzureDeleteIntegrationTests {

    private let environment = AzureIntegrationEnvironment()

    private var container: StorageContainer { StorageContainer(name: environment.container) }

    private func liveProvider() -> AzureBlobProvider {
        AzureBlobProvider(
            displayName: environment.account,
            endpoint: AzureStorageEndpoint(account: environment.account),
            tokenSource: AzureCLITokenProvider()
        )
    }

    /// A fresh prefix per test, so two runs — or two tests in parallel — can never
    /// collide, and nothing outside it is ever in scope.
    private func scratchPrefix() -> String {
        "strata-test/delete-\(UUID().uuidString)/"
    }

    @Test("Lists every key under a prefix with no folders in the way")
    func listsKeysRecursively() async throws {
        let provider = liveProvider()
        let root = scratchPrefix()
        let keys = [root + "top.txt", root + "a/one.txt", root + "a/b/two.txt"]
        try await seed(keys, provider: provider)
        defer { Task { for key in keys { try? await provider.delete(key: key, in: container) } } }

        let listed = try await provider.listAllKeys(under: root, in: container)
        #expect(Set(listed.map(\.key)) == Set(keys))
        // Without a delimiter the service stops synthesising BlobPrefix folders, so what
        // comes back is only real blobs — which is what a delete may act on.
        #expect(listed.allSatisfy { !$0.isPrefix })

        // The browse listing of the same prefix sees one blob and one folder. That
        // difference is the whole reason a folder has to be expanded before deleting.
        let browsed = try await provider.listObjects(in: container, prefix: root)
        #expect(browsed.filter(\.isPrefix).map(\.key) == [root + "a/"])
    }

    @Test("Deletes a folder and everything under it")
    func deletesAFolder() async throws {
        let provider = liveProvider()
        let root = scratchPrefix()
        try await seed([root + "top.txt", root + "a/one.txt", root + "a/b/two.txt"], provider: provider)

        let children = try await provider.listAllKeys(under: root, in: container)
        let plan = DeletionPlan.make(
            selection: [StorageObject(key: root, isPrefix: true)],
            expandedKeys: [root: children]
        )
        // Three blobs plus the prefix itself, which has no blob of its own here.
        #expect(plan.keys.count == 4)
        // The prefix must be last: on a hierarchical-namespace account it is a real
        // directory, and a directory refuses to go while anything is still inside it.
        #expect(plan.batches.last == [root])

        let failures = await DeletionRun(provider: provider, container: container, plan: plan)
            .run { _ in }
        #expect(failures.isEmpty, "unexpected failures: \(failures)")

        let remaining = try await provider.listAllKeys(under: root, in: container)
        #expect(remaining.isEmpty)
    }

    @Test("Deleting removes exactly the blob it was given")
    func deletesOneBlob() async throws {
        let provider = liveProvider()
        let root = scratchPrefix()
        let doomed = root + "doomed.txt"
        let bystander = root + "keep.txt"
        try await seed([doomed, bystander], provider: provider)
        defer { Task { try? await provider.delete(key: bystander, in: container) } }

        try await provider.delete(key: doomed, in: container)

        let remaining = try await provider.listAllKeys(under: root, in: container).map(\.key)
        #expect(remaining == [bystander])
    }

    /// A retry of a partly-failed folder delete asks again for keys that already went,
    /// so a second delete has to be a no-op rather than a 404 dressed up as a failure.
    @Test("Deleting a blob that is already gone is not an error")
    func deleteIsIdempotent() async throws {
        let provider = liveProvider()
        let key = scratchPrefix() + "twice.txt"
        try await seed([key], provider: provider)

        try await provider.delete(key: key, in: container)
        try await provider.delete(key: key, in: container)
    }

    /// What the confirmation sheet asks before it tells the user whether this is
    /// reversible. Any answer is legitimate — including `.unknown`, since reading the
    /// service properties takes a permission a blob-data role may not carry — but it
    /// must come back rather than throw, and it must not claim recovery it can't back up.
    @Test("Reports what the account does with deleted blobs")
    func reportsDeletionRecovery() async throws {
        let recovery = await liveProvider().deletionRecovery(in: container)
        switch recovery {
        case .retained(let days), .versionedAndRetained(let days):
            #expect(days > 0)
            #expect(recovery.isRecoverable)
        case .versioned:
            #expect(recovery.isRecoverable)
        case .permanent, .unknown:
            #expect(recovery.isRecoverable == false)
        }
    }

    /// Writes tiny blobs for a test to delete. Everything lands under the caller's own
    /// scratch prefix.
    private func seed(_ keys: [String], provider: AzureBlobProvider) async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("strata-az-seed-\(UUID().uuidString).txt")
        try Data("seed\n".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        for key in keys {
            try await provider.upload(
                from: source,
                toKey: key,
                in: container,
                contentType: "text/plain",
                plan: UploadPlan(byteCount: 5, target: .azureBlob(endpoint: .blob)),
                onProgress: nil
            )
        }
    }
}

struct AzureIntegrationEnvironment {
    let account: String
    let container: String

    init() {
        let environment = ProcessInfo.processInfo.environment
        account = environment["STRATA_AZ_ACCOUNT"] ?? ""
        container = environment["STRATA_AZ_CONTAINER"] ?? ""
    }

    static var isConfigured: Bool {
        let environment = ProcessInfo.processInfo.environment
        return ["STRATA_AZ_ACCOUNT", "STRATA_AZ_CONTAINER"]
            .allSatisfy { !(environment[$0] ?? "").isEmpty }
    }
}
