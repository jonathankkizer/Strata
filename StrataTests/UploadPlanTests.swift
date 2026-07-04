import Testing
@testable import Strata

/// The differentiator: given an upload, predict the exact Event Grid `data.api`
/// a re-write emits. These are pure value-type checks — no network, no app state.
@Suite("Upload event prediction")
struct UploadPlanTests {

    @Test("Small blob upload commits as PutBlob")
    func smallBlobIsPutBlob() {
        let plan = UploadPlan(byteCount: 1_000, endpoint: .blob)
        #expect(plan.predictedCommitAPI == .putBlob)
    }

    @Test("Blob at the single-shot threshold is still PutBlob (inclusive)")
    func atThresholdIsPutBlob() {
        let plan = UploadPlan(byteCount: UploadPlan.defaultSingleShotThreshold, endpoint: .blob)
        #expect(plan.predictedCommitAPI == .putBlob)
    }

    @Test("One byte over the threshold stages as PutBlockList")
    func overThresholdIsPutBlockList() {
        let plan = UploadPlan(byteCount: UploadPlan.defaultSingleShotThreshold + 1, endpoint: .blob)
        #expect(plan.predictedCommitAPI == .putBlockList)
    }

    // MARK: - DFS endpoint

    @Test("DFS endpoint always commits as FlushWithClose (tiny byte count)")
    func dfsEndpointTinyIsFlushWithClose() {
        let plan = UploadPlan(byteCount: 1, endpoint: .dfs)
        #expect(plan.predictedCommitAPI == .flushWithClose)
    }

    @Test("DFS endpoint always commits as FlushWithClose (huge byte count)")
    func dfsEndpointHugeIsFlushWithClose() {
        let plan = UploadPlan(byteCount: Int64.max, endpoint: .dfs)
        #expect(plan.predictedCommitAPI == .flushWithClose)
    }

    // MARK: - SFTP endpoint

    @Test("SFTP endpoint always commits as SftpCommit (tiny byte count)")
    func sftpEndpointTinyIsSftpCommit() {
        let plan = UploadPlan(byteCount: 1, endpoint: .sftp)
        #expect(plan.predictedCommitAPI == .sftpCommit)
    }

    @Test("SFTP endpoint always commits as SftpCommit (huge byte count)")
    func sftpEndpointHugeIsSftpCommit() {
        let plan = UploadPlan(byteCount: Int64.max, endpoint: .sftp)
        #expect(plan.predictedCommitAPI == .sftpCommit)
    }

    // MARK: - firesBlobCreatedOnCommit

    @Test(
        "firesBlobCreatedOnCommit is true for pipeline-compatible APIs",
        arguments: [BlobWriteAPI.putBlob, .putBlockList, .copyBlob, .flushWithClose]
    )
    func firesBlobCreatedForCompatibleAPIs(api: BlobWriteAPI) {
        #expect(api.firesBlobCreatedOnCommit == true)
    }

    @Test(
        "firesBlobCreatedOnCommit is false for non-standard APIs",
        arguments: [BlobWriteAPI.createFile, .sftpCreate, .sftpCommit]
    )
    func doesNotFireBlobCreatedForNonStandardAPIs(api: BlobWriteAPI) {
        #expect(api.firesBlobCreatedOnCommit == false)
    }

    // MARK: - predictedEventSummary

    @Test("Summary for a small blob contains 'emits BlobCreated with api: PutBlob'")
    func summarySmallBlobContainsPutBlob() {
        let plan = UploadPlan(byteCount: 100, endpoint: .blob)
        #expect(plan.predictedEventSummary.contains("emits BlobCreated with api: PutBlob"))
    }

    @Test("Summary for SFTP upload mentions 'does NOT match standard BlobCreated filters'")
    func summarySftpMentionsNoMatch() {
        let plan = UploadPlan(byteCount: 100, endpoint: .sftp)
        #expect(plan.predictedEventSummary.contains("does NOT match standard BlobCreated filters"))
    }

    // MARK: - Custom singleShotThreshold

    @Test("At a custom threshold of 100, exactly 100 bytes is still PutBlob")
    func customThresholdAtBoundaryIsPutBlob() {
        let plan = UploadPlan(byteCount: 100, endpoint: .blob, singleShotThreshold: 100)
        #expect(plan.predictedCommitAPI == .putBlob)
    }

    @Test("At a custom threshold of 100, 101 bytes is PutBlockList")
    func customThresholdOverBoundaryIsPutBlockList() {
        let plan = UploadPlan(byteCount: 101, endpoint: .blob, singleShotThreshold: 100)
        #expect(plan.predictedCommitAPI == .putBlockList)
    }
}
