import Foundation

/// App-wide user preferences, UserDefaults-backed.
enum StrataDefaults {

    private static let askBeforeUploadingKey = "AskBeforeUploading"

    /// When true, uploads show a confirmation sheet listing each file's predicted
    /// event before starting. Off by default: drops and Upload… begin immediately,
    /// and predictions surface as badges in the Transfers popover.
    static var askBeforeUploading: Bool {
        get { UserDefaults.standard.bool(forKey: askBeforeUploadingKey) }
        set { UserDefaults.standard.set(newValue, forKey: askBeforeUploadingKey) }
    }

    private static let inspectorVisibleKey = "InspectorVisible"

    /// Whether the object inspector pane is shown. Off by default (a new window
    /// opens with the inspector hidden); toggling persists so the last state is
    /// restored on the next launch. `UserDefaults.bool` defaults to false.
    static var inspectorVisible: Bool {
        get { UserDefaults.standard.bool(forKey: inspectorVisibleKey) }
        set { UserDefaults.standard.set(newValue, forKey: inspectorVisibleKey) }
    }

    private static let browseModeKey = "BrowseMode"

    /// The last browse layout (List vs Columns), restored on the next launch.
    /// `UserDefaults.integer` defaults to 0, which is `.list`.
    static var browseMode: Int {
        get { UserDefaults.standard.integer(forKey: browseModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: browseModeKey) }
    }

    private static let sortKeyKey = "BrowseSortKey"
    private static let sortAscendingKey = "BrowseSortAscending"

    /// The last browse sort (field + direction), restored on the next launch.
    /// Unset defaults to Name ascending, matching a fresh `BrowseSort`.
    static var sort: BrowseSort {
        get {
            let key = UserDefaults.standard.string(forKey: sortKeyKey).flatMap(SortKey.init) ?? BrowseSort().key
            let ascending = UserDefaults.standard.object(forKey: sortAscendingKey) as? Bool ?? true
            return BrowseSort(key: key, ascending: ascending)
        }
        set {
            UserDefaults.standard.set(newValue.key.rawValue, forKey: sortKeyKey)
            UserDefaults.standard.set(newValue.ascending, forKey: sortAscendingKey)
        }
    }

    private static let downloadDirectoryKey = "DownloadDirectoryBookmark"

    /// Where plain Download puts files. Stored as a security-scoped-capable bookmark
    /// rather than a path so it survives the folder being renamed or moved, the way
    /// a Mac app's saved location should. Falls back to ~/Downloads.
    static var downloadDirectory: URL {
        get {
            guard let data = UserDefaults.standard.data(forKey: downloadDirectoryKey) else {
                return DownloadPlanning.defaultDirectory
            }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                return DownloadPlanning.defaultDirectory
            }
            return url
        }
        set {
            guard let data = try? newValue.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
            UserDefaults.standard.set(data, forKey: downloadDirectoryKey)
        }
    }

    private static let askWhereToSaveDownloadsKey = "AskWhereToSaveDownloads"

    /// When true, plain Download opens a save panel instead of going straight to the
    /// download folder — Safari's "Ask for each download". Off by default.
    static var askWhereToSaveDownloads: Bool {
        get { UserDefaults.standard.bool(forKey: askWhereToSaveDownloadsKey) }
        set { UserDefaults.standard.set(newValue, forKey: askWhereToSaveDownloadsKey) }
    }

    private static let preferencesPaneKey = "PreferencesPane"

    /// The last-selected Preferences pane identifier, restored when the window
    /// reopens. Nil until the user has switched panes.
    static var preferencesPane: String? {
        get { UserDefaults.standard.string(forKey: preferencesPaneKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferencesPaneKey) }
    }
}
