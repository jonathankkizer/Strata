import Foundation

/// One row in the connect picker, in terms the picker can render without knowing which
/// cloud produced it.
///
/// The two providers enumerate very different things — Azure storage accounts come from
/// the Resource Manager, S3 "accounts" are profiles parsed out of `~/.aws/config` — but
/// the choice being offered is the same shape: a name, something to tell it apart by,
/// and occasionally a badge worth calling out.
struct ConnectableAccount: Sendable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    /// The line under the name: subscription and location for Azure, how the profile
    /// authenticates for S3.
    var detail: String
    /// Shown as a pill when present. Azure uses it for Data Lake (hierarchical
    /// namespace) accounts, which behave differently enough to be worth flagging.
    var badge: String?

    init(name: String, detail: String, badge: String? = nil) {
        self.name = name
        self.detail = detail
        self.badge = badge
    }
}

extension ConnectableAccount {
    init(azure account: StorageAccountRef) {
        self.init(
            name: account.name,
            detail: "\(account.subscriptionName) \u{00B7} \(account.location)",
            badge: account.isHierarchicalNamespace ? "Data Lake" : nil
        )
    }

    init(awsProfile profile: AWSProfile) {
        self.init(
            name: profile.name,
            detail: profile.summary,
            // Worth flagging because it's the one that expires: an SSO session that has
            // lapsed fails at connect time, and `aws sso login` is the fix.
            badge: profile.isSSO ? "SSO" : nil
        )
    }
}
