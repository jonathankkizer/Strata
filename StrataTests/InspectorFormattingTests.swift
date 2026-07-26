import Testing
@testable import Strata

@MainActor
@Suite("Inspector value formatting")
struct InspectorFormattingTests {

    @Test("Strips the quotes Azure wraps around an ETag")
    func stripsQuotes() {
        #expect(InspectorViewController.displayETag("\"0x8DEE126C27919F8\"") == "0x8DEE126C27919F8")
    }

    @Test("Strips a weak validator prefix")
    func stripsWeakValidator() {
        #expect(InspectorViewController.displayETag("W/\"0x8DEE126C27919F8\"") == "0x8DEE126C27919F8")
    }

    @Test("Leaves an already-bare ETag alone")
    func leavesBareValueAlone() {
        #expect(InspectorViewController.displayETag("0x8DEE126C27919F8") == "0x8DEE126C27919F8")
    }

    @Test("Trims surrounding whitespace")
    func trimsWhitespace() {
        #expect(InspectorViewController.displayETag("  \"abc\" ") == "abc")
    }

    /// A lone quote is not a quoted string; dropping first-and-last on a 1-character
    /// input would return empty and lose the only information there was.
    @Test("Doesn't mangle degenerate input")
    func handlesDegenerateInput() {
        #expect(InspectorViewController.displayETag("\"") == "\"")
        #expect(InspectorViewController.displayETag("") == "")
        #expect(InspectorViewController.displayETag("\"\"") == "")
    }
}
