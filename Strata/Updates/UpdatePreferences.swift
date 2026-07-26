import Foundation

/// The update check's own slice of UserDefaults. Separate from `StrataDefaults`, and
/// with an injectable store, so the scheduling rules can be tested without touching
/// the real user's preferences.
/// Not `Sendable`: `UserDefaults` isn't, and this never needs to cross an actor
/// boundary — `UpdateCoordinator` owns it and is `@MainActor`.
struct UpdatePreferences {

    private enum Key {
        static let autoCheckEnabled = "Updates.autoCheckEnabled"
        static let consentPromptShown = "Updates.consentPromptShown"
        static let lastCheckDate = "Updates.lastCheckDate"
        static let skippedVersion = "Updates.skippedVersion"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Off until the user says otherwise: reaching out to a network service on the
    /// user's behalf is opt-in, which is what the one-time consent prompt is for.
    var autoCheckEnabled: Bool {
        get { defaults.object(forKey: Key.autoCheckEnabled) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Key.autoCheckEnabled) }
    }

    var consentPromptShown: Bool {
        get { defaults.bool(forKey: Key.consentPromptShown) }
        nonmutating set { defaults.set(newValue, forKey: Key.consentPromptShown) }
    }

    var lastCheckDate: Date? {
        get { defaults.object(forKey: Key.lastCheckDate) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Key.lastCheckDate) }
    }

    /// A version the user asked not to be told about again. Scheduled checks honour
    /// it; an explicit "Check for Updates…" ignores it, because asking is asking.
    var skippedVersion: String? {
        get { defaults.string(forKey: Key.skippedVersion) }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: Key.skippedVersion)
            } else {
                defaults.removeObject(forKey: Key.skippedVersion)
            }
        }
    }
}
