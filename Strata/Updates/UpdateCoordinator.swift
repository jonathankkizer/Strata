import AppKit
import Foundation

/// Owns the update check's lifecycle: the one-time consent prompt, the weekly
/// re-evaluation, the manual "Check for Updates…" command, and what to do with an
/// answer. The decisions themselves live in `UpdateSchedule`; the modals live in
/// `UpdateAlertController`.
@MainActor
final class UpdateCoordinator {

    static let repositoryOwner = "jonathankkizer"
    static let repositoryName = "Strata"

    private let checker: UpdateChecker
    private let prefs: UpdatePreferences
    private let alerts: UpdateAlertController

    private var isChecking = false
    private var tickTimer: Timer?

    init(
        checker: UpdateChecker? = nil,
        prefs: UpdatePreferences = UpdatePreferences(),
        alerts: UpdateAlertController = UpdateAlertController()
    ) {
        self.checker = checker ?? UpdateChecker(owner: Self.repositoryOwner, repo: Self.repositoryName)
        self.prefs = prefs
        self.alerts = alerts
    }

    // MARK: - Lifecycle

    func start() {
        // The test bundle is app-hosted, so `xcodebuild test` launches this app for
        // real. Nobody is there to answer a modal, and `NSAlert.runModal()` waits
        // forever — which hangs the whole job, including the release workflow's
        // pre-signing test run. Locally the tests happened to finish before the delay
        // below elapsed; a slower runner loses that race, so this can't be left to
        // timing.
        guard !Self.isRunningTests else { return }

        Task { @MainActor in
            // Launch belongs to the app, not to a dialog about updates. Two seconds
            // is enough for the browser or Welcome window to be up and settled.
            try? await Task.sleep(for: .seconds(2))
            presentConsentPromptOnce()
            runScheduledCheckIfDue()
        }
        scheduleTick()
    }

    /// Whether this process was launched as a test host. XCTest's framework is loaded
    /// into the host app, and it sets these variables in the environment, so either
    /// signal alone is enough — both are checked because the Swift Testing bundle
    /// still runs under the XCTest harness.
    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private func scheduleTick() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: UpdateSchedule.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runScheduledCheckIfDue() }
        }
        // Generous tolerance: nothing here is time-critical, and it lets the system
        // coalesce the wake-up instead of holding one for us.
        timer.tolerance = 60 * 60
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    // MARK: - Public surface

    func checkManually() {
        runCheck(isManual: true)
    }

    var isAutoCheckEnabled: Bool { prefs.autoCheckEnabled }

    func setAutoCheckEnabled(_ enabled: Bool) {
        prefs.autoCheckEnabled = enabled
        // Changing the setting is an answer to the question, so don't ask it later.
        prefs.consentPromptShown = true
        if enabled { runScheduledCheckIfDue() }
    }

    // MARK: - Scheduling

    private func runScheduledCheckIfDue() {
        guard prefs.autoCheckEnabled, !isChecking else { return }
        guard UpdateSchedule.isCheckDue(lastCheck: prefs.lastCheckDate, now: Date()) else { return }
        // Never raise a modal over another app's window.
        guard NSApp.isActive else { return }
        runCheck(isManual: false)
    }

    private func presentConsentPromptOnce() {
        guard !prefs.consentPromptShown else { return }
        let choice = alerts.presentConsentPrompt()
        prefs.consentPromptShown = true
        prefs.autoCheckEnabled = (choice == .enable)
    }

    // MARK: - Core check

    private func runCheck(isManual: Bool) {
        guard !isChecking else { return }
        guard let currentVersion = Self.currentVersionString() else {
            if isManual { alerts.presentError(UpdateCheckError.noCurrentVersion) }
            return
        }
        isChecking = true

        Task { @MainActor in
            defer { isChecking = false }

            let status: UpdateStatus
            do {
                status = try await checker.checkForLatest(currentVersionString: currentVersion)
            } catch {
                // A scheduled check that fails stays silent: the user didn't ask, and
                // a dropped network shouldn't produce an alert they have to dismiss.
                if isManual { alerts.presentError(error) }
                return
            }

            prefs.lastCheckDate = Date()

            switch status {
            case .upToDate(let current):
                if isManual { alerts.presentUpToDate(current: current) }

            case .noReleaseFound:
                if isManual { alerts.presentNoReleaseFound() }

            case .updateAvailable(let latest, let current, let release):
                guard isManual || UpdateSchedule.shouldAnnounce(
                    latest: latest,
                    skippedVersion: prefs.skippedVersion
                ) else { return }
                handleUpdateAvailable(latest: latest, current: current, release: release, isManual: isManual)
            }
        }
    }

    private func handleUpdateAvailable(
        latest: SemanticVersion,
        current: SemanticVersion,
        release: GitHubRelease,
        isManual: Bool
    ) {
        switch alerts.presentUpdateAvailable(
            latest: latest,
            current: current,
            release: release,
            offerSkip: !isManual
        ) {
        case .viewRelease:
            // The URL comes from api.github.com over HTTPS, so this is belt-and-braces
            // — but it guarantees NSWorkspace is never handed a file:// URL even if
            // some future path widens where releases come from.
            if release.htmlURL.scheme == "https" {
                NSWorkspace.shared.open(release.htmlURL)
            }
        case .skipVersion:
            prefs.skippedVersion = String(describing: latest)
        case .later:
            break
        }
    }

    // MARK: - Helpers

    /// `CFBundleShortVersionString` is what the release workflow writes from the tag,
    /// so it is the value that lines up with a release tag.
    static func currentVersionString() -> String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
