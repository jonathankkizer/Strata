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

    private static let dontNotifyWhenTransfersFinishKey = "DontNotifyWhenTransfersFinish"

    /// Whether a batch of transfers finishing while Strata is in the background posts
    /// a notification. On by default, so it's stored inverted (`bool` defaults false).
    static var notifyWhenTransfersFinish: Bool {
        get { !UserDefaults.standard.bool(forKey: dontNotifyWhenTransfersFinishKey) }
        set { UserDefaults.standard.set(!newValue, forKey: dontNotifyWhenTransfersFinishKey) }
    }

    private static let sessionKey = "BrowserSession"

    /// The windows and tabs to reopen on the next launch. Nil when there's nothing
    /// saved or it can't be read.
    static var session: BrowserSession? {
        get {
            guard let data = UserDefaults.standard.data(forKey: sessionKey) else { return nil }
            return try? JSONDecoder().decode(BrowserSession.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: sessionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: sessionKey)
            }
        }
    }

    private static let azureCLIPathKey = "AzureCLIPath"
    private static let awsCLIPathKey = "AWSCLIPath"

    /// Where the Azure and AWS CLIs are, when they aren't anywhere Strata looks by
    /// itself. Nil (the default) means find them automatically. Read at each use, so
    /// a change applies to the next token fetch without reconnecting.
    static var azureCLIPath: String? {
        get { UserDefaults.standard.string(forKey: azureCLIPathKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue, forKey: azureCLIPathKey) }
    }

    static var awsCLIPath: String? {
        get { UserDefaults.standard.string(forKey: awsCLIPathKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue, forKey: awsCLIPathKey) }
    }

    private static let inspectorVisibleKey = "InspectorVisible"

    /// Whether the object inspector pane is shown. Off by default (a new window
    /// opens with the inspector hidden); toggling persists so the last state is
    /// restored on the next launch. `UserDefaults.bool` defaults to false.
    static var inspectorVisible: Bool {
        get { UserDefaults.standard.bool(forKey: inspectorVisibleKey) }
        set { UserDefaults.standard.set(newValue, forKey: inspectorVisibleKey) }
    }

    private static let inspectorShowsMoreKey = "InspectorShowsMore"

    /// Whether the inspector's Information section is expanded ("Show More"). Sticks
    /// once chosen, like the Finder's.
    static var inspectorShowsMore: Bool {
        get { UserDefaults.standard.bool(forKey: inspectorShowsMoreKey) }
        set { UserDefaults.standard.set(newValue, forKey: inspectorShowsMoreKey) }
    }

    private static let browseModeKey = "BrowseMode"

    /// The last browse layout (List vs Columns), restored on the next launch.
    /// `UserDefaults.integer` defaults to 0, which is `.list`.
    static var browseMode: Int {
        get { UserDefaults.standard.integer(forKey: browseModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: browseModeKey) }
    }

    private static let columnWidthKey = "BrowseColumnWidth"

    /// How wide a column in the Columns view opens. Set by dragging a column's trailing
    /// divider, so the width the user settled on is the width the next column — and the
    /// next launch — starts at.
    static var columnWidth: CGFloat {
        get { ColumnLayout.restored(CGFloat(UserDefaults.standard.double(forKey: columnWidthKey))) }
        set { UserDefaults.standard.set(Double(ColumnLayout.clamp(newValue)), forKey: columnWidthKey) }
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

    private static let reconnectOnLaunchKey = "ReconnectOnLaunch"

    /// Whether to reconnect to the last account when the app opens. On by default —
    /// an app that forgets where you were every launch is not respecting your time.
    /// `UserDefaults.bool` defaults to false, so the stored sense is inverted.
    static var reconnectOnLaunch: Bool {
        get { !UserDefaults.standard.bool(forKey: reconnectOnLaunchKey) }
        set { UserDefaults.standard.set(!newValue, forKey: reconnectOnLaunchKey) }
    }

    /// Pre-S3 key: a bare Azure storage account name. Still read, never written.
    private static let legacyLastAccountKey = "LastAccount"
    private static let lastAccountKey = "LastProviderAccount"

    /// The last account connected to — which cloud as well as which name. Only
    /// identity is stored; credentials stay in the `az`/`aws` CLIs' own keychains and
    /// caches, which is the whole point of piggybacking them.
    static var lastAccount: ProviderAccount? {
        get {
            if let data = UserDefaults.standard.data(forKey: lastAccountKey),
               let decoded = try? JSONDecoder().decode(ProviderAccount.self, from: data) {
                return decoded
            }
            // Written before S3 support, so it can only have been Azure.
            if let legacy = UserDefaults.standard.string(forKey: legacyLastAccountKey), !legacy.isEmpty {
                return .azure(legacy)
            }
            return nil
        }
        set {
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: lastAccountKey)
                UserDefaults.standard.removeObject(forKey: legacyLastAccountKey)
                return
            }
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: lastAccountKey)
            }
            // Drop the legacy value once it has been superseded, so a later read can't
            // resurrect a stale Azure account after the user moved to S3.
            UserDefaults.standard.removeObject(forKey: legacyLastAccountKey)
        }
    }

    private static let lastContainerKey = "LastContainer"
    private static let lastPrefixKey = "LastPrefix"

    /// The last folder browsed, restored into the first window on relaunch.
    static var lastLocation: BrowserLocation? {
        get {
            guard let container = UserDefaults.standard.string(forKey: lastContainerKey),
                  !container.isEmpty else { return nil }
            return BrowserLocation(
                container: container,
                prefix: UserDefaults.standard.string(forKey: lastPrefixKey) ?? ""
            )
        }
        set {
            UserDefaults.standard.set(newValue?.container, forKey: lastContainerKey)
            UserDefaults.standard.set(newValue?.prefix, forKey: lastPrefixKey)
        }
    }

    private static let showWelcomeOnLaunchKey = "ShowWelcomeOnLaunch"

    /// Whether the Welcome window opens on launch when there's nothing to reconnect
    /// to. On by default — its whole job is the first launch, and that's exactly the
    /// launch with no stored preference. `UserDefaults.bool` defaults to false, so the
    /// stored sense is inverted, the same as `reconnectOnLaunch`.
    static var showWelcomeOnLaunch: Bool {
        get { !UserDefaults.standard.bool(forKey: showWelcomeOnLaunchKey) }
        set { UserDefaults.standard.set(!newValue, forKey: showWelcomeOnLaunchKey) }
    }

    private static let preferencesPaneKey = "PreferencesPane"

    /// The last-selected Preferences pane identifier, restored when the window
    /// reopens. Nil until the user has switched panes.
    static var preferencesPane: String? {
        get { UserDefaults.standard.string(forKey: preferencesPaneKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferencesPaneKey) }
    }
}
