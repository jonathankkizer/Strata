import Testing
@testable import Strata

@Suite("Transfer notifications")
struct TransferSummaryTests {

    private func up(_ name: String, failure: String? = nil) -> TransferSummary.Outcome {
        .init(direction: .upload, fileName: name, failure: failure)
    }
    private func down(_ name: String, failure: String? = nil) -> TransferSummary.Outcome {
        .init(direction: .download, fileName: name, failure: failure)
    }

    @Test("Nothing to say about an empty batch")
    func empty() {
        #expect(TransferSummary.make([]) == nil)
    }

    @Test("One success names the file")
    func oneSuccess() {
        #expect(TransferSummary.make([down("report.csv")]) == .init(title: "Download finished", body: "report.csv"))
    }

    @Test("Many successes are counted, with a couple of names")
    func manySuccesses() {
        let summary = TransferSummary.make([up("a"), up("b"), up("c"), up("d")])
        #expect(summary == .init(title: "4 uploads finished", body: "a, b and 2 more"))
        #expect(TransferSummary.make([up("a"), down("b")])?.title == "2 transfers finished")
    }

    @Test("One failure alone gives its reason")
    func oneFailure() {
        let summary = TransferSummary.make([up("big.bin", failure: "Access to \u{201C}logs\u{201D} was denied.")])
        #expect(summary?.title == "Couldn\u{2019}t upload \u{201C}big.bin\u{201D}")
        #expect(summary?.body == "Access to \u{201C}logs\u{201D} was denied.")
    }

    @Test("Failures among successes say both")
    func mixed() {
        #expect(TransferSummary.make([up("a"), up("b", failure: "x")])?.title == "1 finished, 1 failed")
        let summary = TransferSummary.make([up("a"), up("b", failure: "x"), up("c", failure: "y")])
        #expect(summary == .init(title: "1 finished, 2 failed", body: "Failed: b, c"))
    }
}
