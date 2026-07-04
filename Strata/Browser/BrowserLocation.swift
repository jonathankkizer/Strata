import Foundation

/// A position in the browse hierarchy: a container plus a prefix ("" at the root,
/// otherwise a slash-terminated path like `a/b/`).
struct BrowserLocation: Sendable, Equatable {
    var container: String
    var prefix: String

    /// The prefix split into path segments, e.g. `a/b/` -> ["a", "b"].
    var segments: [String] {
        prefix.split(separator: "/").map(String.init)
    }
}
