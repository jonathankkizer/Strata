import Testing
@testable import Strata

@Suite("SemanticVersion")
struct SemanticVersionTests {

    @Test("Parses the release-tag forms the workflow produces")
    func parsesTagForms() throws {
        let tagged = try #require(SemanticVersion("v1.2.3"))
        #expect((tagged.major, tagged.minor, tagged.patch) == (1, 2, 3))

        let bare = try #require(SemanticVersion("1.2.3"))
        #expect(bare == tagged)

        // A short version string is still a version — 0.1 means 0.1.0.
        let short = try #require(SemanticVersion("0.1"))
        #expect((short.major, short.minor, short.patch) == (0, 1, 0))
        #expect(SemanticVersion("2") == SemanticVersion("2.0.0"))
    }

    @Test("Rejects things that aren't versions")
    func rejectsGarbage() {
        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("v") == nil)
        #expect(SemanticVersion("latest") == nil)
        #expect(SemanticVersion("1.2.3.4") == nil)
        #expect(SemanticVersion("1.x.3") == nil)
        #expect(SemanticVersion("-1.0.0") == nil)
        #expect(SemanticVersion("1.0.0-") == nil)
    }

    /// The reason this type exists rather than comparing tag strings: lexically,
    /// "0.10.0" sorts below "0.9.0", which would silently stop offering updates.
    @Test("Orders numerically, not lexically")
    func ordersNumerically() throws {
        let ten = try #require(SemanticVersion("0.10.0"))
        let nine = try #require(SemanticVersion("0.9.0"))
        #expect(ten > nine)
        #expect(try #require(SemanticVersion("1.0.0")) > #require(SemanticVersion("0.99.99")))
        #expect(try #require(SemanticVersion("0.1.2")) > #require(SemanticVersion("0.1.1")))
    }

    @Test("A pre-release ranks below the release it precedes")
    func prereleaseOrdering() throws {
        let beta = try #require(SemanticVersion("1.0.0-beta"))
        let release = try #require(SemanticVersion("1.0.0"))
        #expect(beta < release)
        #expect(try #require(SemanticVersion("1.0.0-alpha")) < #require(SemanticVersion("1.0.0-beta")))
        // Numeric identifiers compare numerically and rank below alphanumeric ones.
        #expect(try #require(SemanticVersion("1.0.0-2")) < #require(SemanticVersion("1.0.0-10")))
        #expect(try #require(SemanticVersion("1.0.0-1")) < #require(SemanticVersion("1.0.0-alpha")))
        // Fewer identifiers ranks lower when the shared prefix is equal.
        #expect(try #require(SemanticVersion("1.0.0-beta")) < #require(SemanticVersion("1.0.0-beta.1")))
    }

    @Test("Round-trips through its description")
    func roundTrips() throws {
        for text in ["0.1.0", "1.2.3", "1.0.0-beta.2"] {
            let parsed = try #require(SemanticVersion(text))
            #expect(String(describing: parsed) == text)
            #expect(SemanticVersion(String(describing: parsed)) == parsed)
        }
    }
}
