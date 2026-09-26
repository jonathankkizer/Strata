import Testing
import Foundation
@testable import Strata

/// TODO.md U12.
@Suite("Browser session")
struct BrowserSessionTests {

    private let tab = BrowserSession.Tab(account: .azure("acct"), container: "data", prefix: "raw/", mode: 1)

    @Test("A session round-trips through JSON")
    func roundTrip() throws {
        let session = BrowserSession(windows: [
            .init(tabs: [tab, .init(account: .s3(profile: "dev"), container: nil, prefix: "", mode: 0)], selectedTab: 1, frame: "0 0 800 600 0 0 1920 1080 "),
        ])
        let decoded = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(session))
        #expect(decoded == session)
        #expect(decoded.windows[0].tabs[0].location == BrowserLocation(container: "data", prefix: "raw/"))
        #expect(decoded.windows[0].tabs[1].location == nil)
    }

    @Test("Empty windows are dropped and a bad tab index is clamped")
    func sanitized() {
        let session = BrowserSession(windows: [
            .init(tabs: [], selectedTab: 0, frame: nil),
            .init(tabs: [tab], selectedTab: 7, frame: nil),
        ]).sanitized()
        #expect(session.windows.count == 1)
        #expect(session.windows[0].selectedTab == 0)
    }

    @Test("A saved session is restored when reconnecting is on, and not otherwise")
    func launchPlan() {
        let session = BrowserSession(windows: [.init(tabs: [tab], selectedTab: 0, frame: nil)])
        #expect(LaunchPlan.decide(reconnectOnLaunch: true, lastAccount: .azure("acct"), showWelcomeOnLaunch: true, session: session) == .restoreSession)
        #expect(LaunchPlan.decide(reconnectOnLaunch: false, lastAccount: .azure("acct"), showWelcomeOnLaunch: true, session: session) == .welcome)
        #expect(LaunchPlan.decide(reconnectOnLaunch: true, lastAccount: .azure("acct"), showWelcomeOnLaunch: true, session: BrowserSession(windows: [])) == .reconnectingBrowser)
    }
}
