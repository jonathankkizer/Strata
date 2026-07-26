import Foundation

/// A parsed `major.minor.patch[-prerelease]` version, ordered per SemVer 2.0.0.
///
/// Needed because comparing release tags as strings gets `0.10.0 < 0.9.0` wrong,
/// which would silently stop offering updates after the tenth minor release.
struct SemanticVersion: Sendable, Equatable, Comparable, CustomStringConvertible {

    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [PrereleaseIdentifier]

    enum PrereleaseIdentifier: Sendable, Equatable, Comparable {
        case numeric(Int)
        case alphanumeric(String)

        static func < (lhs: PrereleaseIdentifier, rhs: PrereleaseIdentifier) -> Bool {
            switch (lhs, rhs) {
            case let (.numeric(a), .numeric(b)): return a < b
            case (.numeric, .alphanumeric): return true
            case (.alphanumeric, .numeric): return false
            case let (.alphanumeric(a), .alphanumeric(b)): return a < b
            }
        }
    }

    /// Tolerates the leading `v` that git tags carry (`v0.1.0`) and a missing minor
    /// or patch component, so both a tag and a `CFBundleShortVersionString` parse.
    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        guard !text.isEmpty else { return nil }

        let coreAndPre = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = coreAndPre[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count >= 1, core.count <= 3 else { return nil }

        let numbers = core.map { Int($0) }
        guard numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        self.major = numbers[0]!
        self.minor = numbers.count > 1 ? numbers[1]! : 0
        self.patch = numbers.count > 2 ? numbers[2]! : 0

        if coreAndPre.count == 2 {
            let parts = coreAndPre[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
            self.prerelease = parts.map { part in
                if let number = Int(part), number >= 0 {
                    return .numeric(number)
                }
                return .alphanumeric(String(part))
            }
        } else {
            self.prerelease = []
        }
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // SemVer 2.0.0: a pre-release version has lower precedence than the
        // release it precedes, so 1.0.0-beta < 1.0.0.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false):
            for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
                return left < right
            }
            return lhs.prerelease.count < rhs.prerelease.count
        }
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        guard !prerelease.isEmpty else { return core }
        let pre = prerelease.map { identifier in
            switch identifier {
            case .numeric(let number): return String(number)
            case .alphanumeric(let text): return text
            }
        }.joined(separator: ".")
        return "\(core)-\(pre)"
    }
}
