import Foundation

/// What a launch should open. Pure so the branching is testable directly rather than
/// by quitting and relaunching with different preferences set.
enum LaunchPlan: Equatable {
    /// Every window and tab from last time, each reconnecting to its own account.
    case restoreSession
    /// A browser window, which will reconnect to the last account on appearance.
    case reconnectingBrowser
    /// The Welcome window only. It supersedes an empty browser window rather than
    /// appearing in front of one.
    case welcome
    /// An empty browser window — what the app did before the Welcome window existed.
    case emptyBrowser

    /// Reconnecting wins over the Welcome window: it lands the user somewhere useful,
    /// and a launcher stacked in front of it would just be in the way.
    ///
    /// A saved session wins over a single reconnect: it's the same promise, kept for
    /// every window rather than one.
    static func decide(
        reconnectOnLaunch: Bool,
        lastAccount: ProviderAccount?,
        showWelcomeOnLaunch: Bool,
        session: BrowserSession? = nil
    ) -> LaunchPlan {
        if reconnectOnLaunch, let session, !session.sanitized().isEmpty { return .restoreSession }
        let hasAccount = !(lastAccount?.isEmpty ?? true)
        if reconnectOnLaunch && hasAccount { return .reconnectingBrowser }
        return showWelcomeOnLaunch ? .welcome : .emptyBrowser
    }
}
