import Foundation

/// Ordered Azure credential strategies, in the priority the app tries them.
/// The single most important UX win: respect credentials the user already has.
/// Typing a secret is the fallback, not the default.
enum AzureCredentialSource: Sendable, Hashable {
    /// Piggyback the existing `az login` session by shelling out to mint a
    /// data-plane token on demand — the mechanism AzureCliCredential uses.
    case azureCLI(subscription: String?, tenant: String?)
    /// Native interactive login via MSAL for Apple platforms — no CLI dependency.
    case interactiveMSAL(tenant: String?)
    /// Client-credentials grant (CI/CD, Functions/Logic Apps).
    case servicePrincipal(clientID: String, tenant: String)
    /// Shared Key signing, no Entra involved.
    case accountKey
    /// Scoped/shared access; prefer user-delegation SAS over account-key SAS.
    case sasToken
}

/// The data-plane token scope, identical across all public and sovereign clouds
/// and valid for any storage account.
enum AzureAuth {
    static let storageResource = "https://storage.azure.com/"
    static let storageScope = "https://storage.azure.com/.default"

    /// Candidate paths for the `az` binary. GUI apps launched from Finder do not
    /// inherit the shell PATH, so the CLI must be resolved explicitly (with a
    /// Preferences override on top of these).
    static let azureCLISearchPaths = [
        "/opt/homebrew/bin/az",
        "/usr/local/bin/az",
        "/usr/bin/az",
    ]
}

/// A minted data-plane token plus its expiry. Cache and refresh ~5 min before
/// `expiresOn`; never invoke `az` (a ~1–2s cold-start Python script) on the hot
/// path of every request.
struct AzureAccessToken: Sendable {
    var accessToken: String
    var expiresOn: Date
    var tenant: String?
    var subscription: String?
}

/// Anything that can supply a valid Azure data-plane token. The REST client
/// depends on this rather than a concrete provider, so CLI piggyback, MSAL, and
/// service-principal sources are interchangeable.
protocol AzureTokenSource: Sendable {
    func token(asOf now: Date) async throws -> AzureAccessToken
}
