import Foundation

/// What a launch should open. Pure so the branching is testable directly rather than
/// by quitting and relaunching with different preferences set.
enum LaunchPlan: Equatable {
    /// A browser window, which will reconnect to the last account on appearance.
    case reconnectingBrowser
    /// The Welcome window only. It supersedes an empty browser window rather than
    /// appearing in front of one.
    case welcome
    /// An empty browser window — what the app did before the Welcome window existed.
    case emptyBrowser

    /// Reconnecting wins over the Welcome window: it lands the user somewhere useful,
    /// and a launcher stacked in front of it would just be in the way.
    static func decide(
        reconnectOnLaunch: Bool,
        lastAccount: ProviderAccount?,
        showWelcomeOnLaunch: Bool
    ) -> LaunchPlan {
        let hasAccount = !(lastAccount?.isEmpty ?? true)
        if reconnectOnLaunch && hasAccount { return .reconnectingBrowser }
        return showWelcomeOnLaunch ? .welcome : .emptyBrowser
    }
}
