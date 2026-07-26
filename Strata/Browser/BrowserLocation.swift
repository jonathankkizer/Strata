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

// Parsing lives in an extension so the memberwise `init(container:prefix:)` — used
// throughout the browser — survives.
extension BrowserLocation {

    /// The display form used by the path bar, Copy Path, and Go to Folder:
    /// `container` at the root, otherwise `container/a/b`.
    var path: String {
        segments.isEmpty ? container : ([container] + segments).joined(separator: "/")
    }

    /// Parses a path the user typed into Go to Folder. Tolerates the shapes people
    /// actually paste — leading and trailing slashes, repeated slashes, surrounding
    /// whitespace, and a full `https://…/container/key` blob URL.
    ///
    /// Returns nil when there is no container to land in.
    init?(path: String) {
        var text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // A pasted blob URL: keep everything after the host.
        if let url = URL(string: text), let scheme = url.scheme, scheme.hasPrefix("http") {
            text = url.path
        }

        let parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let container = parts.first else { return nil }

        self.container = container
        // Every prefix is slash-terminated so it composes with a blob key directly.
        let rest = parts.dropFirst()
        self.prefix = rest.isEmpty ? "" : rest.map { $0 + "/" }.joined()
    }
}
