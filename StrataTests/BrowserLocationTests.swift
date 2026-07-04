import Testing
@testable import Strata

@Suite("BrowserLocation")
struct BrowserLocationTests {

    // MARK: - segments

    @Test("Two-level prefix splits into two segments")
    func twoLevelPrefix() {
        let loc = BrowserLocation(container: "c", prefix: "a/b/")
        #expect(loc.segments == ["a", "b"])
    }

    @Test("Empty prefix yields no segments")
    func emptyPrefix() {
        let loc = BrowserLocation(container: "c", prefix: "")
        #expect(loc.segments == [])
    }

    @Test("Single-level prefix yields one segment")
    func singleLevelPrefix() {
        let loc = BrowserLocation(container: "c", prefix: "a/")
        #expect(loc.segments == ["a"])
    }

    @Test("Three-level prefix splits into three segments")
    func threeLevelPrefix() {
        let loc = BrowserLocation(container: "c", prefix: "x/y/z/")
        #expect(loc.segments == ["x", "y", "z"])
    }

    // MARK: - Equatable

    @Test("Two BrowserLocations with the same container and prefix are equal")
    func equalLocations() {
        let a = BrowserLocation(container: "mycontainer", prefix: "a/b/")
        let b = BrowserLocation(container: "mycontainer", prefix: "a/b/")
        #expect(a == b)
    }

    @Test("Different containers are not equal")
    func differentContainersNotEqual() {
        let a = BrowserLocation(container: "alpha", prefix: "a/b/")
        let b = BrowserLocation(container: "beta", prefix: "a/b/")
        #expect(a != b)
    }

    @Test("Different prefixes are not equal")
    func differentPrefixesNotEqual() {
        let a = BrowserLocation(container: "c", prefix: "x/")
        let b = BrowserLocation(container: "c", prefix: "y/")
        #expect(a != b)
    }

    @Test("Root location (empty prefix) equals another root location in same container")
    func rootLocationsEqual() {
        let a = BrowserLocation(container: "data", prefix: "")
        let b = BrowserLocation(container: "data", prefix: "")
        #expect(a == b)
    }
}
