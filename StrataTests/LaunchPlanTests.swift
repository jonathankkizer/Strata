import Testing
@testable import Strata

@Suite("Launch plan")
struct LaunchPlanTests {

    @Test("Reconnecting beats the Welcome window")
    func reconnectWins() {
        #expect(LaunchPlan.decide(
            reconnectOnLaunch: true,
            lastAccount: "acct",
            showWelcomeOnLaunch: true
        ) == .reconnectingBrowser)
    }

    /// The first launch: nothing stored, and the preference defaults on.
    @Test("Nothing to reconnect to shows the Welcome window")
    func firstLaunchShowsWelcome() {
        #expect(LaunchPlan.decide(
            reconnectOnLaunch: true,
            lastAccount: nil,
            showWelcomeOnLaunch: true
        ) == .welcome)
    }

    @Test("Reconnect turned off shows the Welcome window even with an account")
    func reconnectOffShowsWelcome() {
        #expect(LaunchPlan.decide(
            reconnectOnLaunch: false,
            lastAccount: "acct",
            showWelcomeOnLaunch: true
        ) == .welcome)
    }

    @Test("Welcome turned off with nothing to reconnect to opens an empty browser")
    func welcomeOffFallsBackToBrowser() {
        #expect(LaunchPlan.decide(
            reconnectOnLaunch: true,
            lastAccount: nil,
            showWelcomeOnLaunch: false
        ) == .emptyBrowser)
        #expect(LaunchPlan.decide(
            reconnectOnLaunch: false,
            lastAccount: nil,
            showWelcomeOnLaunch: false
        ) == .emptyBrowser)
    }

    /// A stored empty string is not an account. Writing one would otherwise send the
    /// browser off to connect to nothing and skip the Welcome window while doing it.
    @Test("An empty stored account counts as no account")
    func emptyAccountIsNoAccount() {
        #expect(LaunchPlan.decide(
            reconnectOnLaunch: true,
            lastAccount: "",
            showWelcomeOnLaunch: true
        ) == .welcome)
    }
}
