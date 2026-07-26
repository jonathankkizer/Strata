import Foundation

/// The update check's decisions, kept free of AppKit and of the clock so they can be
/// tested directly rather than inferred from a week of waiting.
enum UpdateSchedule {

    /// How long between automatic checks. Weekly: often enough to hear about a
    /// release in reasonable time, rare enough that it never feels like telemetry.
    static let interval: TimeInterval = 7 * 24 * 60 * 60

    /// How often to re-evaluate due-ness. The app may well be running for days, so
    /// the interval alone isn't enough — something has to come back and look.
    static let tickInterval: TimeInterval = 24 * 60 * 60

    /// A check has never run, or the interval has elapsed. A `lastCheckDate` in the
    /// future (a clock that moved backwards) counts as due rather than locking the
    /// check out until the date passes again.
    static func isCheckDue(lastCheck: Date?, now: Date, interval: TimeInterval = interval) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed >= interval || elapsed < 0
    }

    /// Whether a scheduled check should surface `latest`. Skipping 0.4.0 also skips
    /// anything at or below it, so a user who skipped a version isn't re-asked by an
    /// older tag; 0.4.1 still gets through.
    static func shouldAnnounce(latest: SemanticVersion, skippedVersion: String?) -> Bool {
        guard let skippedVersion, let skipped = SemanticVersion(skippedVersion) else { return true }
        return latest > skipped
    }
}
