import Testing
import Foundation
@testable import Strata

/// Exercises the update check against canned GitHub payloads served by a URLProtocol
/// stub — no network, no live repository. The `repo` name selects the scenario, so
/// there is no shared mutable state between tests (Swift Testing runs them in
/// parallel).
@Suite("Update check")
struct UpdateCheckTests {

    private static let currentVersion = "0.2.0"

    private func checker(scenario: String) -> UpdateChecker {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReleaseStubURLProtocol.self]
        return UpdateChecker(
            owner: "owner",
            repo: scenario,
            session: URLSession(configuration: config)
        )
    }

    private func status(_ scenario: String, current: String = currentVersion) async throws -> UpdateStatus {
        try await checker(scenario: scenario).checkForLatest(currentVersionString: current)
    }

    // MARK: - Happy paths

    @Test("A newer tag is offered, with its release notes and page")
    func newerTagIsOffered() async throws {
        guard case let .updateAvailable(latest, current, release) = try await status("newer") else {
            Issue.record("expected an available update")
            return
        }
        #expect(String(describing: latest) == "0.3.0")
        #expect(String(describing: current) == "0.2.0")
        #expect(release.htmlURL.absoluteString == "https://github.com/owner/newer/releases/tag/v0.3.0")
        #expect(release.body == "Fixed the thing.")
    }

    @Test("The same or an older tag reports up to date")
    func sameOrOlderIsUpToDate() async throws {
        guard case .upToDate = try await status("same") else {
            Issue.record("expected up to date for an identical tag")
            return
        }
        guard case .upToDate = try await status("older") else {
            Issue.record("expected up to date for an older tag")
            return
        }
    }

    /// The state Strata is actually in today: private repository, no releases cut.
    /// It has to be a distinct, calm answer rather than an HTTP error.
    @Test("404 means no release found, not a failure")
    func notFoundIsItsOwnAnswer() async throws {
        guard case .noReleaseFound = try await status("missing") else {
            Issue.record("expected noReleaseFound for a 404")
            return
        }
    }

    @Test("A draft or pre-release is never offered")
    func draftsAndPrereleasesAreIgnored() async throws {
        guard case .upToDate = try await status("draft") else {
            Issue.record("expected a draft to be ignored")
            return
        }
        guard case .upToDate = try await status("prerelease") else {
            Issue.record("expected a pre-release to be ignored")
            return
        }
    }

    // MARK: - Failures

    @Test("A tag that isn't a version is reported as such")
    func malformedTagThrows() async throws {
        await #expect(throws: UpdateCheckError.self) {
            _ = try await status("malformed")
        }
    }

    @Test("A server error surfaces its status code")
    func serverErrorThrows() async throws {
        do {
            _ = try await status("server-error")
            Issue.record("expected a throw")
        } catch let error as UpdateCheckError {
            guard case .http(let code) = error else {
                Issue.record("expected .http, got \(error)")
                return
            }
            #expect(code == 500)
        }
    }

    @Test("Unparseable JSON is reported as a decoding failure")
    func badJSONThrows() async throws {
        do {
            _ = try await status("bad-json")
            Issue.record("expected a throw")
        } catch let error as UpdateCheckError {
            guard case .decoding = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
        }
    }

    @Test("An unreadable current version fails before any request")
    func unknownCurrentVersionThrows() async throws {
        do {
            _ = try await status("newer", current: "not-a-version")
            Issue.record("expected a throw")
        } catch let error as UpdateCheckError {
            guard case .noCurrentVersion = error else {
                Issue.record("expected .noCurrentVersion, got \(error)")
                return
            }
        }
    }
}

// MARK: - Scheduling

@Suite("Update scheduling")
struct UpdateScheduleTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A check that has never run is due")
    func neverCheckedIsDue() {
        #expect(UpdateSchedule.isCheckDue(lastCheck: nil, now: now))
    }

    @Test("Due only once the interval has elapsed")
    func intervalGates() {
        let justChecked = now.addingTimeInterval(-60)
        #expect(!UpdateSchedule.isCheckDue(lastCheck: justChecked, now: now))

        let sixDaysAgo = now.addingTimeInterval(-6 * 24 * 60 * 60)
        #expect(!UpdateSchedule.isCheckDue(lastCheck: sixDaysAgo, now: now))

        let eightDaysAgo = now.addingTimeInterval(-8 * 24 * 60 * 60)
        #expect(UpdateSchedule.isCheckDue(lastCheck: eightDaysAgo, now: now))
    }

    /// A clock that jumped backwards (or a defaults file copied from another Mac)
    /// shouldn't lock the check out until the future date passes.
    @Test("A last-check date in the future counts as due")
    func futureDateIsDue() {
        #expect(UpdateSchedule.isCheckDue(lastCheck: now.addingTimeInterval(9999), now: now))
    }

    @Test("Announces anything newer when nothing was skipped")
    func announcesWithoutSkip() throws {
        let version = try #require(SemanticVersion("0.3.0"))
        #expect(UpdateSchedule.shouldAnnounce(latest: version, skippedVersion: nil))
        // An unparseable stored value must not silence updates forever.
        #expect(UpdateSchedule.shouldAnnounce(latest: version, skippedVersion: "garbage"))
    }

    @Test("A skipped version stays skipped, but the next one gets through")
    func skipSuppressesOnlyUpToThatVersion() throws {
        #expect(!UpdateSchedule.shouldAnnounce(
            latest: try #require(SemanticVersion("0.3.0")),
            skippedVersion: "0.3.0"
        ))
        // Older than the skipped version: still nothing to say.
        #expect(!UpdateSchedule.shouldAnnounce(
            latest: try #require(SemanticVersion("0.2.5")),
            skippedVersion: "0.3.0"
        ))
        #expect(UpdateSchedule.shouldAnnounce(
            latest: try #require(SemanticVersion("0.3.1")),
            skippedVersion: "0.3.0"
        ))
    }
}

// MARK: - Preferences

@Suite("Update preferences")
struct UpdatePreferencesTests {

    /// Its own suite domain per test, since Swift Testing runs in parallel and
    /// `.standard` is the real user's preferences.
    private func withPreferences(_ body: (UpdatePreferences) -> Void) {
        let name = "com.kizersolutions.strata.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        body(UpdatePreferences(defaults: defaults))
        defaults.removePersistentDomain(forName: name)
    }

    @Test("Automatic checking is off until asked for")
    func autoCheckDefaultsOff() {
        withPreferences { prefs in
            #expect(prefs.autoCheckEnabled == false)
            #expect(prefs.consentPromptShown == false)
            #expect(prefs.lastCheckDate == nil)
            #expect(prefs.skippedVersion == nil)
        }
    }

    @Test("Values round-trip, and a skip can be cleared")
    func roundTrips() {
        withPreferences { prefs in
            prefs.autoCheckEnabled = true
            #expect(prefs.autoCheckEnabled)

            let date = Date(timeIntervalSince1970: 1_700_000_000)
            prefs.lastCheckDate = date
            #expect(prefs.lastCheckDate == date)

            prefs.skippedVersion = "0.3.0"
            #expect(prefs.skippedVersion == "0.3.0")
            prefs.skippedVersion = nil
            #expect(prefs.skippedVersion == nil)
        }
    }
}

// MARK: - Stub

/// Serves a canned `releases/latest` payload chosen by the repository name in the
/// request path, so each test picks its scenario without shared mutable state.
private final class ReleaseStubURLProtocol: URLProtocol {

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        // .../repos/owner/<scenario>/releases/latest
        let scenario = url.pathComponents.dropLast(2).last ?? ""
        let (statusCode, body) = Self.response(for: scenario)
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func response(for scenario: String) -> (Int, String) {
        switch scenario {
        case "newer":
            return (200, release(tag: "v0.3.0", repo: scenario))
        case "same":
            return (200, release(tag: "v0.2.0", repo: scenario))
        case "older":
            return (200, release(tag: "v0.1.0", repo: scenario))
        case "draft":
            return (200, release(tag: "v0.3.0", repo: scenario, draft: true))
        case "prerelease":
            return (200, release(tag: "v0.3.0", repo: scenario, prerelease: true))
        case "malformed":
            return (200, release(tag: "nightly", repo: scenario))
        case "missing":
            return (404, #"{ "message": "Not Found" }"#)
        case "server-error":
            return (500, #"{ "message": "Server Error" }"#)
        case "bad-json":
            return (200, "{ this is not json")
        default:
            return (200, release(tag: "v0.0.1", repo: scenario))
        }
    }

    private static func release(
        tag: String,
        repo: String,
        draft: Bool = false,
        prerelease: Bool = false
    ) -> String {
        """
        {
          "tag_name": "\(tag)",
          "name": "Strata \(tag)",
          "body": "Fixed the thing.",
          "html_url": "https://github.com/owner/\(repo)/releases/tag/\(tag)",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "published_at": "2026-07-26T12:00:00Z"
        }
        """
    }
}
