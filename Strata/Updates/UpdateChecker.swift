import Foundation

/// The subset of GitHub's release payload this app reads.
struct GitHubRelease: Sendable, Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let publishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case draft
        case prerelease
        case publishedAt = "published_at"
    }
}

enum UpdateStatus: Sendable {
    case upToDate(current: SemanticVersion)
    case updateAvailable(latest: SemanticVersion, current: SemanticVersion, release: GitHubRelease)
    /// The repository has no published release to compare against. Distinct from an
    /// error because it is the expected answer before the first tag is cut — and,
    /// while the repository is private, the expected answer full stop: the releases
    /// endpoint answers 404 rather than 403 to an unauthenticated caller, so this
    /// covers both without pretending to tell them apart.
    case noReleaseFound
}

enum UpdateCheckError: Error, LocalizedError {
    case noCurrentVersion
    case malformedRemoteVersion(String)
    case http(Int)
    case transport(any Error)
    case decoding(any Error)

    var errorDescription: String? {
        switch self {
        case .noCurrentVersion:
            return "Could not determine the current app version."
        case .malformedRemoteVersion(let tag):
            return "The latest release tag (\"\(tag)\") isn't a recognizable version number."
        case .http(let code):
            return "GitHub returned HTTP \(code) while checking for updates."
        case .transport(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .decoding:
            return "GitHub's response couldn't be parsed."
        }
    }
}

/// Asks the GitHub Releases API whether a newer version has shipped. Deliberately
/// not Sparkle: this reads one public JSON endpoint and, when there is something
/// newer, sends you to the release page to download it — no updater framework, no
/// background installer, no signing key beyond the Developer ID the DMG already
/// carries.
struct UpdateChecker: Sendable {

    let owner: String
    let repo: String
    let session: URLSession

    init(owner: String, repo: String, session: URLSession = .shared) {
        self.owner = owner
        self.repo = repo
        self.session = session
    }

    func checkForLatest(currentVersionString: String) async throws -> UpdateStatus {
        guard let current = SemanticVersion(currentVersionString) else {
            throw UpdateCheckError.noCurrentVersion
        }

        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Strata-macOS/\(currentVersionString)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateCheckError.transport(error)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { return .noReleaseFound }
            guard (200..<300).contains(http.statusCode) else {
                throw UpdateCheckError.http(http.statusCode)
            }
        }

        let release: GitHubRelease
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            release = try decoder.decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateCheckError.decoding(error)
        }

        // `releases/latest` already excludes both, but the field is authoritative and
        // the check is free — a manually re-tagged draft shouldn't prompt anyone.
        if release.draft || release.prerelease {
            return .upToDate(current: current)
        }

        guard let latest = SemanticVersion(release.tagName) else {
            throw UpdateCheckError.malformedRemoteVersion(release.tagName)
        }

        return latest > current
            ? .updateAvailable(latest: latest, current: current, release: release)
            : .upToDate(current: current)
    }
}
