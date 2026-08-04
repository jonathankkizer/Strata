import Testing
@testable import Strata

/// The differentiator, generalised. Azure's behaviour is pinned by `UploadPlanTests`;
/// this covers the neutral `PredictedWriteEvent` both providers now produce, and the
/// S3 side of it.
@Suite("Write event prediction")
struct WriteEventPredictionTests {

    // MARK: - S3

    @Test("A small object commits as a plain PutObject")
    func smallObjectIsPut() {
        let plan = UploadPlan(byteCount: 1_000, target: .s3)
        #expect(plan.s3Operation == .put)
        #expect(plan.usesMultipleRequests == false)
        #expect(plan.predictedEvent.eventName == "s3:ObjectCreated:Put")
    }

    @Test("An object at the multipart threshold is still a single request")
    func atThresholdIsPut() {
        let plan = UploadPlan(byteCount: UploadPlan.defaultS3MultipartThreshold, target: .s3)
        #expect(plan.s3Operation == .put)
    }

    @Test("One byte over the threshold goes multipart")
    func overThresholdIsMultipart() {
        let plan = UploadPlan(byteCount: UploadPlan.defaultS3MultipartThreshold + 1, target: .s3)
        #expect(plan.s3Operation == .completeMultipartUpload)
        #expect(plan.usesMultipleRequests)
        #expect(plan.predictedEvent.eventName == "s3:ObjectCreated:CompleteMultipartUpload")
    }

    /// The whole point of predicting on S3: a notification narrowed to
    /// `s3:ObjectCreated:Put` silently misses every multipart upload. If this ever
    /// stops warning, the feature has stopped earning its place.
    @Test("A multipart upload warns that a Put-only notification won't fire")
    func multipartWarnsAboutPutOnlyFilters() {
        let event = UploadPlan(
            byteCount: UploadPlan.defaultS3MultipartThreshold + 1,
            target: .s3
        ).predictedEvent

        #expect(event.confidence.isReassuring == false)
        #expect(event.confidence.message.contains("s3:ObjectCreated:Put"))
        #expect(S3WriteOperation.completeMultipartUpload.missedByPutOnlyFilter)
        #expect(S3WriteOperation.put.missedByPutOnlyFilter == false)
    }

    @Test("A single-request upload is reported as firing")
    func singleRequestReassures() {
        let event = UploadPlan(byteCount: 10, target: .s3).predictedEvent
        #expect(event.confidence.isReassuring)
        #expect(event.systemName == "Event Notifications")
    }

    @Test("S3 defaults to the 8 MiB threshold the AWS CLI uses, not Azure's 256 MiB")
    func s3UsesItsOwnDefaultThreshold() {
        #expect(UploadPlan(byteCount: 0, target: .s3).singleShotThreshold == 8 * 1024 * 1024)
        #expect(UploadPlan(byteCount: 0, target: .azureBlob(endpoint: .blob)).singleShotThreshold == 256 * 1024 * 1024)
        // An explicit threshold still wins over the per-provider default.
        #expect(UploadPlan(byteCount: 0, target: .s3, singleShotThreshold: 99).singleShotThreshold == 99)
    }

    // MARK: - Azure, through the neutral surface

    @Test("Azure predictions come through in Event Grid's vocabulary")
    func azureSpeaksEventGrid() {
        let small = UploadPlan(byteCount: 10, target: .azureBlob(endpoint: .blob)).predictedEvent
        #expect(small.systemName == "Event Grid")
        #expect(small.eventName == "PutBlob")
        #expect(small.emissionSummary == "BlobCreated · api: PutBlob")
        #expect(small.confidence.isReassuring)

        let staged = UploadPlan(
            byteCount: UploadPlan.defaultSingleShotThreshold + 1,
            target: .azureBlob(endpoint: .blob)
        ).predictedEvent
        #expect(staged.eventName == "PutBlockList")
        #expect(staged.confidence.isReassuring)
    }

    @Test("An SFTP write still warns, through the neutral surface")
    func sftpWarns() {
        let event = UploadPlan(byteCount: 10, target: .azureBlob(endpoint: .sftp)).predictedEvent
        #expect(event.eventName == "SftpCommit")
        #expect(event.confidence.isReassuring == false)
        #expect(event.summary.contains("SftpCommit"))
    }

    // MARK: - Provider separation

    @Test("Each provider's accessor is nil for the other's plans")
    func accessorsAreProviderSpecific() {
        let azure = UploadPlan(byteCount: 10, target: .azureBlob(endpoint: .blob))
        #expect(azure.azureCommitAPI != nil)
        #expect(azure.s3Operation == nil)

        let s3 = UploadPlan(byteCount: 10, target: .s3)
        #expect(s3.s3Operation != nil)
        #expect(s3.azureCommitAPI == nil)
    }

    @Test("Default targets follow the provider")
    func defaultTargetPerProvider() {
        #expect(UploadTarget.default(for: .s3) == .s3)
        #expect(UploadTarget.default(for: .azureBlob) == .azureBlob(endpoint: .blob))
    }

    /// Event Grid filter matching is Azure-only; handing it an S3 plan must not report
    /// a confident miss it has no basis for.
    @Test("Event Grid filter matching reports unknown for an S3 plan")
    func filterMatchingIgnoresNonAzurePlans() {
        let match = EventPredictionService.match(
            plan: UploadPlan(byteCount: 10, target: .s3),
            againstFilter: ["PutBlob"]
        )
        #expect(match == .unknownNoManagementAccess)
    }

    @Test("Event Grid filter matching still works for Azure plans")
    func filterMatchingWorksForAzure() {
        let plan = UploadPlan(byteCount: 10, target: .azureBlob(endpoint: .blob))
        #expect(EventPredictionService.match(plan: plan, againstFilter: ["PutBlob"]) == .willFire)
        #expect(EventPredictionService.match(plan: plan, againstFilter: ["CopyBlob"])
            == .willNotFire(emitted: .putBlob, filter: ["CopyBlob"]))
    }
}
