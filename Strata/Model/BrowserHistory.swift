import Foundation

/// Back/forward history for one browser window — Safari's model, which is also the
/// one Finder uses: visiting a new place after going back discards what was ahead.
///
/// Pure value type with no AppKit or UI dependency, so the whole traversal policy is
/// unit-testable headlessly.
struct BrowserHistory: Sendable, Equatable {

    /// Enough to cover any realistic session without growing without bound.
    static let capacity = 100

    private(set) var entries: [BrowserLocation] = []
    /// Index into `entries`; -1 when nothing has been visited yet.
    private(set) var index: Int = -1

    var current: BrowserLocation? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < entries.count - 1 }

    /// Records a location reached by ordinary navigation. Re-recording the current
    /// location is ignored, so a refresh or a redundant callback doesn't pile up
    /// duplicate entries the user would have to press Back through twice.
    mutating func record(_ location: BrowserLocation) {
        if current == location { return }

        // Anything ahead of the cursor is now an alternate future that didn't happen.
        if canGoForward {
            entries.removeSubrange((index + 1)...)
        }
        entries.append(location)

        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        index = entries.count - 1
    }

    /// Steps back and returns the location to show, or nil at the start of history.
    mutating func goBack() -> BrowserLocation? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }

    /// Steps forward and returns the location to show, or nil at the end of history.
    mutating func goForward() -> BrowserLocation? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }

    /// Drops everything — used when the connected account changes, since locations
    /// from a previous account are meaningless.
    mutating func reset() {
        entries.removeAll()
        index = -1
    }
}
