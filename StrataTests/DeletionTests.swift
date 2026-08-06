import Testing
import Foundation
@testable import Strata

@Suite("Deletion plans")
struct DeletionPlanTests {

    private func blob(_ key: String, size: Int64 = 0) -> StorageObject {
        StorageObject(key: key, size: size)
    }

    private func folder(_ key: String) -> StorageObject {
        StorageObject(key: key, isPrefix: true)
    }

    @Test("One object deletes exactly itself")
    func singleObject() {
        let plan = DeletionPlan.make(selection: [blob("logs/app.log", size: 120)])
        #expect(plan.keys == ["logs/app.log"])
        #expect(plan.title == "Delete \u{201C}app.log\u{201D}?")
        #expect(plan.totalBytes == 120)
        #expect(plan.hasFolders == false)
    }

    @Test("Several objects are counted, not named")
    func severalObjects() {
        let plan = DeletionPlan.make(selection: [blob("a.txt"), blob("b.txt"), blob("c.txt")])
        #expect(plan.title == "Delete 3 items?")
        #expect(plan.keys.count == 3)
    }

    /// The whole reason the sheet does a listing first: the user picked one row, and
    /// this is how many objects that row really stands for.
    @Test("A folder expands to every key underneath it")
    func folderExpands() {
        let plan = DeletionPlan.make(
            selection: [folder("logs/")],
            expandedKeys: ["logs/": [blob("logs/a.log", size: 10), blob("logs/deep/b.log", size: 20)]]
        )
        #expect(plan.keys.count == 3)   // both objects, plus the prefix itself
        #expect(plan.keys.contains("logs/a.log"))
        #expect(plan.keys.contains("logs/deep/b.log"))
        #expect(plan.totalBytes == 30)
        #expect(plan.expandedBeyondSelection)
        #expect(plan.title == "Delete \u{201C}logs\u{201D}?")
    }

    /// A hierarchical-namespace account has real directories that refuse to be deleted
    /// while anything is inside them, so children have to go first.
    @Test("Keys are batched deepest first")
    func batchesGoDeepestFirst() throws {
        let plan = DeletionPlan.make(
            selection: [folder("logs/")],
            expandedKeys: ["logs/": [blob("logs/a.log"), blob("logs/deep/b.log"), blob("logs/deep/deeper/c.log")]]
        )
        let batches = plan.batches
        // "logs/deep/deeper/c.log" is deepest; "logs/" is the shallowest and must be last.
        #expect(batches.first?.first == "logs/deep/deeper/c.log")
        #expect(batches.last == ["logs/"])
        #expect(batches.flatMap { $0 }.count == plan.keys.count)
    }

    @Test("A folder inside another selected folder isn't deleted twice")
    func nestedSelectionIsDeduplicated() {
        let plan = DeletionPlan.make(
            selection: [folder("logs/"), folder("logs/deep/")],
            expandedKeys: [
                "logs/": [blob("logs/a.log"), blob("logs/deep/b.log")],
                "logs/deep/": [blob("logs/deep/b.log")],
            ]
        )
        #expect(plan.keys.count == Set(plan.keys).count)
        #expect(plan.keys.filter { $0 == "logs/deep/b.log" }.count == 1)
    }

    /// The prefix is asked for even when nothing under it is an object of its own: on a
    /// hierarchical account it is a real directory, and on a flat one a zero-byte marker
    /// blob may be sitting at exactly that key. Deleting a key that was never there
    /// succeeds on both clouds.
    @Test("The folder's own key is included")
    func folderKeyItselfIsDeleted() {
        let plan = DeletionPlan.make(selection: [folder("empty/")], expandedKeys: ["empty/": []])
        #expect(plan.keys == ["empty/"])
    }

    @Test("A mixed selection counts objects and folders separately")
    func mixedSelection() {
        let plan = DeletionPlan.make(
            selection: [blob("top.txt"), folder("logs/")],
            expandedKeys: ["logs/": [blob("logs/a.log")]]
        )
        #expect(plan.selectedObjectCount == 1)
        #expect(plan.selectedFolderCount == 1)
        #expect(plan.title == "Delete 2 items?")
        #expect(plan.detail.hasPrefix("3 objects"))
    }

    @Test("An empty selection has nothing to do")
    func emptySelection() {
        let plan = DeletionPlan.make(selection: [])
        #expect(plan.isEmpty)
        #expect(plan.batches.isEmpty)
    }

    @Test("The detail line counts objects and adds a size when there is one")
    func detailWording() {
        let one = DeletionPlan.make(selection: [blob("a.txt")])
        #expect(one.detail == "1 object")

        let sized = DeletionPlan.make(selection: [blob("a.txt", size: 2_000_000)])
        #expect(sized.detail.hasPrefix("1 object \u{2022} "))
    }
}

@Suite("Deletion recovery")
struct DeletionRecoveryTests {

    @Test("Neither versioning nor retention means gone")
    func nothingKept() {
        #expect(DeletionRecovery.from(versioningEnabled: false, retentionDays: nil) == .permanent)
        #expect(DeletionRecovery.permanent.isRecoverable == false)
    }

    @Test("Azure soft delete reports its window")
    func softDelete() {
        let recovery = DeletionRecovery.from(versioningEnabled: false, retentionDays: 7)
        #expect(recovery == .retained(days: 7))
        #expect(recovery.isRecoverable)
        #expect(recovery.summary.contains("7 days"))
    }

    @Test("A one-day window is not pluralised")
    func singularDay() {
        #expect(DeletionRecovery.retained(days: 1).summary.contains("1 day."))
    }

    @Test("S3 versioning has no window, only a kept version")
    func versioning() {
        let recovery = DeletionRecovery.from(versioningEnabled: true, retentionDays: nil)
        #expect(recovery == .versioned)
        #expect(recovery.isRecoverable)
    }

    @Test("Both settings are reported together")
    func versioningAndRetention() {
        #expect(
            DeletionRecovery.from(versioningEnabled: true, retentionDays: 30)
                == .versionedAndRetained(days: 30)
        )
    }

    /// An enabled policy set to zero days retains nothing, and reassuring somebody with
    /// it would be worse than saying nothing.
    @Test("A zero-day retention window is not recovery")
    func zeroDayRetentionIsPermanent() {
        #expect(DeletionRecovery.from(versioningEnabled: false, retentionDays: 0) == .permanent)
    }

    /// Not being able to read the policy must never read as "it's fine".
    @Test("An unreadable policy is not treated as recoverable")
    func unknownIsNotRecoverable() {
        #expect(DeletionRecovery.unknown.isRecoverable == false)
        #expect(DeletionRecovery.unknown.summary.contains("can\u{2019}t be undone"))
    }
}

@Suite("Retention policy parsing")
struct RetentionPolicyParsingTests {

    @Test("Reads blob soft delete and versioning")
    func parsesBoth() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <StorageServiceProperties>
            <DeleteRetentionPolicy><Enabled>true</Enabled><Days>7</Days></DeleteRetentionPolicy>
            <IsVersioningEnabled>true</IsVersioningEnabled>
        </StorageServiceProperties>
        """
        let parsed = try BlobServicePropertiesXMLParser().parse(Data(xml.utf8))
        #expect(parsed.versioningEnabled)
        #expect(parsed.retentionDays == 7)
    }

    /// `ContainerDeleteRetentionPolicy` has identically-named children and retains whole
    /// containers, not blobs — mistaking it for the blob policy would promise a recovery
    /// that does not exist for the thing being deleted.
    @Test("The container retention policy is not mistaken for the blob one")
    func ignoresContainerPolicy() throws {
        let xml = """
        <StorageServiceProperties>
            <DeleteRetentionPolicy><Enabled>false</Enabled></DeleteRetentionPolicy>
            <ContainerDeleteRetentionPolicy><Enabled>true</Enabled><Days>30</Days></ContainerDeleteRetentionPolicy>
            <IsVersioningEnabled>false</IsVersioningEnabled>
        </StorageServiceProperties>
        """
        let parsed = try BlobServicePropertiesXMLParser().parse(Data(xml.utf8))
        #expect(parsed.retentionDays == nil)
        #expect(parsed.versioningEnabled == false)
    }

    @Test("A disabled policy reports no window even when it names days")
    func disabledPolicyIgnoresDays() throws {
        let xml = """
        <StorageServiceProperties>
            <DeleteRetentionPolicy><Enabled>false</Enabled><Days>7</Days></DeleteRetentionPolicy>
        </StorageServiceProperties>
        """
        let parsed = try BlobServicePropertiesXMLParser().parse(Data(xml.utf8))
        #expect(parsed.retentionDays == nil)
    }

    @Test("An account with nothing configured reports nothing")
    func emptyProperties() throws {
        let parsed = try BlobServicePropertiesXMLParser().parse(Data("<StorageServiceProperties/>".utf8))
        #expect(parsed.versioningEnabled == false)
        #expect(parsed.retentionDays == nil)
    }

    /// S3's answer, read with the same element scan the error parser uses. The root
    /// element carries an xmlns, which is what broke `GetBucketLocation` once already.
    @Test("S3 bucket versioning is read through the namespaced root")
    func s3VersioningStatus() {
        let enabled = """
        <?xml version="1.0" encoding="UTF-8"?>
        <VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Status>Enabled</Status></VersioningConfiguration>
        """
        #expect(S3ErrorXMLParser.element("Status", in: enabled) == "Enabled")

        // A bucket that never had versioning answers with an empty configuration.
        let never = """
        <VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"/>
        """
        #expect(S3ErrorXMLParser.element("Status", in: never) == nil)

        let suspended = "<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>"
        #expect(S3ErrorXMLParser.element("Status", in: suspended) != "Enabled")
    }
}

/// Records what it was asked to delete, and can be told to refuse specific keys.
private actor RecordingProvider {
    private(set) var deleted: [String] = []
    private let failing: Set<String>

    init(failing: Set<String> = []) { self.failing = failing }

    func record(_ key: String) throws {
        deleted.append(key)
        if failing.contains(key) {
            throw StorageProviderError.dataPlaneForbidden(account: "test")
        }
    }

    func keys() -> [String] { deleted }
}

private struct DeletingProvider: StorageProvider {
    let kind: ProviderKind = .s3
    let displayName = "test"
    let recorder: RecordingProvider

    func delete(key: String, in container: StorageContainer) async throws {
        try await recorder.record(key)
    }

    func listContainers() async throws -> [StorageContainer] { [] }
    func listObjects(in container: StorageContainer, prefix: String) async throws -> [StorageObject] { [] }
    func listAllKeys(under prefix: String, in container: StorageContainer) async throws -> [StorageObject] { [] }
    func deletionRecovery(in container: StorageContainer) async -> DeletionRecovery { .permanent }
    func fetchMetadata(for object: StorageObject, in container: StorageContainer) async throws -> ObjectMetadata {
        throw StorageProviderError.notImplemented
    }
    func objectURL(forKey key: String, in container: StorageContainer) -> URL? { nil }
    func upload(from fileURL: URL, toKey key: String, in container: StorageContainer, contentType: String?, plan: UploadPlan, onProgress: (@Sendable (Int64, Int64) -> Void)?) async throws {
        throw StorageProviderError.notImplemented
    }
    func download(fromKey key: String, in container: StorageContainer, to destinationURL: URL, onProgress: (@Sendable (Int64, Int64) -> Void)?) async throws {
        throw StorageProviderError.notImplemented
    }
}

@Suite("Running a deletion")
struct DeletionRunTests {

    private func run(
        plan: DeletionPlan,
        failing: Set<String> = []
    ) async -> (failures: [DeletionFailure], deleted: [String], progress: ProgressRecorder) {
        let recorder = RecordingProvider(failing: failing)
        let run = DeletionRun(
            provider: DeletingProvider(recorder: recorder),
            container: StorageContainer(name: "bucket"),
            plan: plan
        )
        let progress = ProgressRecorder()
        let failures = await run.run { progress.record(Int64($0)) }
        return (failures, await recorder.keys(), progress)
    }

    @Test("Every key in the plan is deleted")
    func deletesEverything() async {
        let plan = DeletionPlan.make(selection: (1...20).map { StorageObject(key: "file\($0).txt") })
        let result = await run(plan: plan)
        #expect(result.deleted.count == 20)
        #expect(Set(result.deleted) == Set(plan.keys))
        #expect(result.failures.isEmpty)
    }

    /// Stopping at the first failure in the middle of a folder would leave the user with
    /// no idea what did and didn't go.
    @Test("A refused key doesn't stop the rest")
    func failuresAreCollectedNotThrown() async {
        let plan = DeletionPlan.make(selection: [
            StorageObject(key: "a.txt"), StorageObject(key: "b.txt"), StorageObject(key: "c.txt"),
        ])
        let result = await run(plan: plan, failing: ["b.txt"])
        #expect(result.deleted.count == 3)
        #expect(result.failures.map(\.key) == ["b.txt"])
    }

    /// A directory on a hierarchical account refuses to go while anything is inside it,
    /// so the parent must not even be in flight alongside its children.
    @Test("Children are deleted before their parent")
    func parentGoesLast() async {
        let plan = DeletionPlan.make(
            selection: [StorageObject(key: "logs/", isPrefix: true)],
            expandedKeys: ["logs/": [
                StorageObject(key: "logs/a.log"),
                StorageObject(key: "logs/deep/b.log"),
            ]]
        )
        let result = await run(plan: plan)
        let parentIndex = try? #require(result.deleted.firstIndex(of: "logs/"))
        #expect(parentIndex == result.deleted.count - 1)
        #expect(result.deleted.firstIndex(of: "logs/deep/b.log")! < result.deleted.firstIndex(of: "logs/a.log")!)
    }

    @Test("Progress ends on the exact count")
    func progressReachesTheTotal() async throws {
        let plan = DeletionPlan.make(selection: (1...25).map { StorageObject(key: "file\($0).txt") })
        let result = await run(plan: plan)
        let (last, monotonic) = result.progress.snapshot()
        let finished = try #require(last)
        #expect(finished == 25, "final progress tick was \(finished)")
        // A bar that goes backwards is worse than no bar.
        #expect(monotonic)
    }

    @Test("An empty plan does nothing at all")
    func emptyPlan() async {
        let result = await run(plan: DeletionPlan.make(selection: []))
        #expect(result.deleted.isEmpty)
        #expect(result.failures.isEmpty)
        #expect(result.progress.count == 0)
    }
}
