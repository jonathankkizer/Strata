import Foundation

/// Which account, on which cloud. The pair is the unit of identity everywhere a
/// connection is remembered — favorites, the last-connected account, the window
/// title.
///
/// A bare name isn't enough once there is more than one provider: an Azure storage
/// account and an AWS profile can both be called `prod`, and a saved place that only
/// records `"prod"` cannot say which cloud to reconnect to. That ambiguity is
/// unrecoverable after the fact, which is why this exists before S3 does.
///
/// Region is deliberately *not* part of identity. For S3 it comes from the profile's
/// configuration (and per-bucket resolution), so folding it in here would mean a
/// favorite silently pinning a region that the user's config later changes.
struct ProviderAccount: Sendable, Hashable, Codable, Identifiable {

    var kind: ProviderKind
    /// Azure: the storage account name. S3: the AWS profile name.
    var name: String

    /// Stable across launches and unique per provider, so it can key a dictionary or
    /// a preview-cache path without two clouds colliding on a shared name.
    var id: String { "\(kind.rawValue):\(name)" }

    init(kind: ProviderKind, name: String) {
        self.kind = kind
        self.name = name
    }

    static func azure(_ account: String) -> ProviderAccount {
        ProviderAccount(kind: .azureBlob, name: account)
    }

    static func s3(profile: String) -> ProviderAccount {
        ProviderAccount(kind: .s3, name: profile)
    }

    /// Just the name: within a window the provider is already established by the
    /// subtitle, and prefixing every title with the cloud's name would be noise.
    var displayName: String { name }

    /// Disambiguated, for lists that can span providers — the Welcome window's saved
    /// places, the Go menu.
    var qualifiedName: String { "\(name) — \(kind.displayName)" }

    var isEmpty: Bool { name.isEmpty }
}
