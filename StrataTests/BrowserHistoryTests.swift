import Foundation
import Testing
@testable import Strata

@Suite("Browser history")
struct BrowserHistoryTests {

    private func location(_ path: String) -> BrowserLocation {
        BrowserLocation(path: path)!
    }

    @Test("A fresh history can go nowhere")
    func empty() {
        let history = BrowserHistory()
        #expect(history.current == nil)
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
    }

    @Test("One visit is the current location but still has nowhere to go back to")
    func singleVisit() {
        var history = BrowserHistory()
        history.record(location("data"))
        #expect(history.current == location("data"))
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
    }

    @Test("Back and forward walk the visited trail")
    func backAndForward() {
        var history = BrowserHistory()
        history.record(location("data"))
        history.record(location("data/raw"))
        history.record(location("data/raw/2026"))

        #expect(history.goBack() == location("data/raw"))
        #expect(history.goBack() == location("data"))
        #expect(!history.canGoBack)
        #expect(history.goBack() == nil)

        #expect(history.goForward() == location("data/raw"))
        #expect(history.goForward() == location("data/raw/2026"))
        #expect(!history.canGoForward)
        #expect(history.goForward() == nil)
    }

    @Test("Visiting somewhere new after going back discards the forward trail")
    func newVisitTruncatesForward() {
        var history = BrowserHistory()
        history.record(location("data"))
        history.record(location("data/raw"))
        history.record(location("data/raw/2026"))
        _ = history.goBack()
        _ = history.goBack()
        #expect(history.canGoForward)

        history.record(location("other"))

        #expect(history.current == location("other"))
        #expect(!history.canGoForward)
        // The trail behind is intact: "other" replaced only what was ahead.
        #expect(history.goBack() == location("data"))
    }

    @Test("Re-recording the current location is ignored")
    func duplicateVisitIgnored() {
        var history = BrowserHistory()
        history.record(location("data"))
        history.record(location("data/raw"))
        history.record(location("data/raw"))
        history.record(location("data/raw"))

        // One Back should reach "data", not sit on duplicates of "data/raw".
        #expect(history.goBack() == location("data"))
        #expect(!history.canGoBack)
    }

    @Test("Returning to a previously visited place still records a new entry")
    func revisitRecords() {
        var history = BrowserHistory()
        history.record(location("data"))
        history.record(location("data/raw"))
        history.record(location("data"))

        #expect(history.current == location("data"))
        #expect(history.goBack() == location("data/raw"))
    }

    @Test("History is bounded, keeping the most recent entries")
    func capacity() {
        var history = BrowserHistory()
        for index in 0..<(BrowserHistory.capacity + 20) {
            history.record(location("data/folder\(index)"))
        }
        #expect(history.entries.count == BrowserHistory.capacity)
        #expect(history.current == location("data/folder\(BrowserHistory.capacity + 19)"))
        // The oldest entries were dropped, not the newest.
        #expect(history.entries.first == location("data/folder20"))
    }

    @Test("Reset clears everything, as when the account changes")
    func reset() {
        var history = BrowserHistory()
        history.record(location("data"))
        history.record(location("data/raw"))
        history.reset()

        #expect(history.current == nil)
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
    }
}

@Suite("BrowserLocation path parsing")
struct BrowserLocationPathTests {

    @Test("A bare container is the container root")
    func containerOnly() {
        let location = BrowserLocation(path: "data")
        #expect(location?.container == "data")
        #expect(location?.prefix == "")
    }

    @Test("A nested path becomes a slash-terminated prefix")
    func nestedPath() {
        let location = BrowserLocation(path: "data/raw/2026")
        #expect(location?.container == "data")
        #expect(location?.prefix == "raw/2026/")
    }

    @Test("Stray slashes and whitespace are tolerated")
    func messyInput() {
        #expect(BrowserLocation(path: "  /data//raw//  ") == BrowserLocation(container: "data", prefix: "raw/"))
        #expect(BrowserLocation(path: "data/raw/") == BrowserLocation(container: "data", prefix: "raw/"))
    }

    @Test("Empty or slash-only input has nowhere to go")
    func degenerateInput() {
        #expect(BrowserLocation(path: "") == nil)
        #expect(BrowserLocation(path: "   ") == nil)
        #expect(BrowserLocation(path: "///") == nil)
    }

    @Test("A pasted blob URL resolves to its container and folder")
    func pastedBlobURL() {
        let location = BrowserLocation(path: "https://acct.blob.core.windows.net/data/raw/2026/report.csv")
        #expect(location?.container == "data")
        #expect(location?.prefix == "raw/2026/report.csv/")
    }

    @Test("path round-trips through the parser")
    func roundTrip() {
        let original = BrowserLocation(container: "data", prefix: "raw/2026/")
        #expect(original.path == "data/raw/2026")
        #expect(BrowserLocation(path: original.path) == original)
    }

    @Test("A container root round-trips too")
    func rootRoundTrip() {
        let root = BrowserLocation(container: "data", prefix: "")
        #expect(root.path == "data")
        #expect(BrowserLocation(path: root.path) == root)
    }
}
