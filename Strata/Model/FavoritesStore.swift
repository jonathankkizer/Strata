import Foundation

extension Notification.Name {
    /// Favorites were added, removed, renamed, or reordered. Every open window's
    /// sidebar listens, so all of them stay in step.
    static let favoritesDidChange = Notification.Name("StrataFavoritesDidChange")
}

/// The user's favorites, in their chosen order, persisted across launches.
///
/// `defaults` is injectable so tests exercise the real store against a scratch
/// suite rather than a stand-in.
@MainActor
final class FavoritesStore {

    static let shared = FavoritesStore()

    private static let storageKey = "Favorites"
    /// Where the stored favorites are copied if any of them can't be read.
    static let unreadableBackupKey = "FavoritesUnreadableBackup"

    private let defaults: UserDefaults
    private(set) var favorites: [Favorite] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Queries

    var isEmpty: Bool { favorites.isEmpty }

    func favorite(withID id: UUID) -> Favorite? {
        favorites.first { $0.id == id }
    }

    /// Whether this exact place is already saved — drives "Add to Sidebar" being
    /// disabled rather than silently creating a second copy.
    func contains(account: ProviderAccount, location: BrowserLocation) -> Bool {
        favorites.contains {
            $0.account == account && $0.container == location.container && $0.prefix == location.prefix
        }
    }

    // MARK: - Mutations

    /// Adds a favorite unless the same place is already saved. Returns whether it
    /// was added, so callers can beep rather than appear to do nothing.
    @discardableResult
    func add(_ favorite: Favorite, at index: Int? = nil) -> Bool {
        guard !favorites.contains(where: { $0.refersToSamePlace(as: favorite) }) else { return false }
        let target = index.map { max(0, min($0, favorites.count)) } ?? favorites.count
        favorites.insert(favorite, at: target)
        commit()
        return true
    }

    func remove(id: UUID) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        favorites.remove(at: index)
        commit()
    }

    /// Renames a favorite. An empty or whitespace-only name clears the custom name,
    /// so the favorite falls back to the folder's own name rather than going blank.
    func rename(id: UUID, to name: String?) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        favorites[index].customName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        commit()
    }

    /// Moves a favorite, where `destination` is an insertion index in the list *as it
    /// stands before the move* — which is what NSOutlineView's drop callback reports.
    func move(id: UUID, to destination: Int) {
        guard let from = favorites.firstIndex(where: { $0.id == id }) else { return }
        guard destination >= 0, destination <= favorites.count else { return }
        // Removing the item first shifts everything after it down by one.
        let adjusted = destination > from ? destination - 1 : destination
        guard adjusted != from else { return }
        let moved = favorites.remove(at: from)
        favorites.insert(moved, at: min(adjusted, favorites.count))
        commit()
    }

    // MARK: - Persistence

    private func commit() {
        persist()
        NotificationCenter.default.post(name: .favoritesDidChange, object: self)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Decodes entry by entry, so one favorite this build can't read — written by a
    /// newer version, say, or damaged — costs that one entry rather than the whole
    /// list. Decoding the array in one go would turn a single bad entry into an empty
    /// sidebar, and the next save would then overwrite everything for good.
    ///
    /// When anything is skipped, the original bytes are copied aside first (once), so
    /// the skipped entries are never destroyed by a later save.
    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        guard let entries = try? JSONDecoder().decode([LossyFavorite].self, from: data) else {
            preserveUnreadable(data)
            return
        }
        let readable = entries.compactMap(\.favorite)
        if readable.count < entries.count { preserveUnreadable(data) }
        favorites = readable
    }

    private func preserveUnreadable(_ data: Data) {
        guard defaults.data(forKey: Self.unreadableBackupKey) == nil else { return }
        defaults.set(data, forKey: Self.unreadableBackupKey)
    }
}

/// One element of the stored array, which decodes to `nil` instead of failing the
/// whole array.
private struct LossyFavorite: Decodable {
    let favorite: Favorite?

    init(from decoder: any Decoder) throws {
        favorite = try? Favorite(from: decoder)
    }
}
