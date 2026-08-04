import Foundation

/// A saved place: an account plus a container and folder within it.
///
/// A container root is just a favorite with an empty prefix, so containers and deep
/// folders need no special cases anywhere downstream. The account travels with the
/// favorite so it can jump across accounts — reconnecting on the way if needed —
/// rather than only being useful inside the session that created it.
struct Favorite: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var account: ProviderAccount
    var container: String
    var prefix: String
    /// A favorite is a bookmark, not the folder, so it may be renamed freely. Nil
    /// means "use the folder's own name".
    var customName: String?

    init(
        id: UUID = UUID(),
        account: ProviderAccount,
        container: String,
        prefix: String,
        customName: String? = nil
    ) {
        self.id = id
        self.account = account
        self.container = container
        self.prefix = prefix
        self.customName = customName
    }

    init(id: UUID = UUID(), account: ProviderAccount, location: BrowserLocation, customName: String? = nil) {
        self.init(
            id: id,
            account: account,
            container: location.container,
            prefix: location.prefix,
            customName: customName
        )
    }

    var location: BrowserLocation {
        BrowserLocation(container: container, prefix: prefix)
    }

    /// True when this points at a whole container rather than a folder inside one.
    var isContainerRoot: Bool { prefix.isEmpty }

    /// What the sidebar and the Go menu show: the custom name if there is one, else
    /// the deepest folder segment, else the container.
    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        return location.segments.last ?? container
    }

    /// Identity for duplicate checks — two favorites are "the same place" when they
    /// point at the same folder, whatever they are called.
    func refersToSamePlace(as other: Favorite) -> Bool {
        account == other.account && container == other.container && prefix == other.prefix
    }
}

// MARK: - Migration

extension Favorite {

    private enum CodingKeys: String, CodingKey {
        case id, account, container, prefix, customName
    }

    /// Favorites saved before S3 support stored `account` as a bare string, because
    /// Azure was the only provider. Decoding those into `ProviderAccount` has to be
    /// tolerant of both shapes, and the failure mode if it isn't is the worst kind:
    /// `FavoritesStore.load` decodes the whole array with `try?`, so one unreadable
    /// entry would silently take every saved place with it.
    ///
    /// A legacy entry can only have been Azure, so that's what it becomes.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        container = try values.decode(String.self, forKey: .container)
        prefix = try values.decode(String.self, forKey: .prefix)
        customName = try values.decodeIfPresent(String.self, forKey: .customName)

        if let account = try? values.decode(ProviderAccount.self, forKey: .account) {
            self.account = account
        } else {
            self.account = .azure(try values.decode(String.self, forKey: .account))
        }
    }
}
