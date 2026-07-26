import Testing
import Foundation
@testable import Strata

@Suite("AWS config file parsing")
struct AWSConfigFileTests {

    private let config = """
        [default]
        region = us-east-1
        output = json

        # a comment
        ; another comment
        [profile sandbox]
        region = eu-west-2
        sso_session = my-sso
        sso_account_id = 111122223333

        [profile deploy]
        role_arn = arn:aws:iam::444455556666:role/Deploy
        source_profile = default

        [profile legacy-sso]
        sso_start_url = https://example.awsapps.com/start
        region = us-west-2

        [sso-session my-sso]
        sso_region = us-east-1
        sso_start_url = https://example.awsapps.com/start
        """

    private let credentials = """
        [default]
        aws_access_key_id = AKIAIOSFODNN7EXAMPLE
        aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

        [keys-only]
        aws_access_key_id = AKIAI44QH8DHBEXAMPLE
        aws_secret_access_key = je7MtGbClwBF/2Zp9Utk/h3yCo8nvbEXAMPLEKEY
        """

    private func parse() -> [AWSProfile] {
        AWSConfigFile.profiles(configContents: config, credentialsContents: credentials)
    }

    @Test("Lists profiles from both files with default first")
    func listsProfilesDefaultFirst() {
        #expect(parse().map(\.name) == ["default", "deploy", "keys-only", "legacy-sso", "sandbox"])
    }

    /// `[sso-session x]` is configuration for a session, not a profile. Listing it
    /// would offer the user something they cannot connect to.
    @Test("An sso-session block is not a profile")
    func ssoSessionIsNotAProfile() {
        #expect(parse().contains { $0.name == "my-sso" } == false)
        #expect(AWSConfigFile.profileName(fromConfigSection: "sso-session my-sso") == nil)
        #expect(AWSConfigFile.profileName(fromConfigSection: "default") == "default")
        #expect(AWSConfigFile.profileName(fromConfigSection: "profile foo") == "foo")
        #expect(AWSConfigFile.profileName(fromConfigSection: "profile") == nil)
    }

    @Test("Recognises both spellings of an SSO profile")
    func detectsSSO() throws {
        let profiles = parse()
        #expect(try #require(profiles.first { $0.name == "sandbox" }).isSSO)
        #expect(try #require(profiles.first { $0.name == "legacy-sso" }).isSSO)
        #expect(try #require(profiles.first { $0.name == "default" }).isSSO == false)
    }

    @Test("Recognises an assume-role profile and carries the region")
    func detectsRoleAndRegion() throws {
        let deploy = try #require(parse().first { $0.name == "deploy" })
        #expect(deploy.assumesRole)
        #expect(deploy.region == nil)

        let sandbox = try #require(parse().first { $0.name == "sandbox" })
        #expect(sandbox.region == "eu-west-2")
        #expect(sandbox.assumesRole == false)
    }

    /// A profile that exists only in `~/.aws/credentials` is still connectable.
    @Test("Credentials-only profiles are included")
    func credentialsOnlyProfileIncluded() throws {
        let keysOnly = try #require(parse().first { $0.name == "keys-only" })
        #expect(keysOnly.isSSO == false)
        #expect(keysOnly.summary == "Access keys")
    }

    @Test("The config file wins where a profile appears in both")
    func configWinsOverCredentials() throws {
        #expect(try #require(parse().first { $0.name == "default" }).region == "us-east-1")
    }

    @Test("No configuration at all is an empty list, not a failure")
    func missingFilesAreEmpty() {
        #expect(AWSConfigFile.profiles(configContents: nil, credentialsContents: nil).isEmpty)
        #expect(AWSConfigFile.profiles(configContents: "", credentialsContents: "").isEmpty)
    }

    /// The CLI writes nested blocks for some settings; their indented keys must not be
    /// mistaken for the profile's own.
    @Test("Nested settings blocks don't leak keys into the profile")
    func nestedBlocksSkipped() throws {
        let profiles = AWSConfigFile.profiles(
            configContents: """
                [profile big]
                region = us-east-1
                s3 =
                  max_concurrent_requests = 20
                  multipart_threshold = 64MB
                role_arn = arn:aws:iam::1:role/R
                """,
            credentialsContents: nil
        )
        let profile = try #require(profiles.first)
        #expect(profile.region == "us-east-1")
        // Picked up after the nested block ended, so parsing resumed correctly.
        #expect(profile.assumesRole)
    }

    @Test("Tolerates extra whitespace and inline padding")
    func tolerantOfWhitespace() throws {
        let profiles = AWSConfigFile.profiles(
            configContents: "[profile   spaced ]\n   region   =   ap-southeast-2   \n",
            credentialsContents: nil
        )
        let profile = try #require(profiles.first)
        #expect(profile.name == "spaced")
        #expect(profile.region == "ap-southeast-2")
    }

    @Test("A summary describes how the profile authenticates")
    func summaryDescribesAuth() throws {
        let profiles = parse()
        #expect(try #require(profiles.first { $0.name == "sandbox" }).summary
            == "IAM Identity Center · eu-west-2")
        #expect(try #require(profiles.first { $0.name == "deploy" }).summary == "assumes a role")
    }
}

@Suite("AWS CLI credential provider")
struct AWSCLICredentialProviderTests {

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Builds a provider over canned CLI output, and counts invocations so the caching
    /// behaviour is observable.
    private func makeProvider(
        profile: String = "default",
        outputs: [String]
    ) -> (AWSCLICredentialProvider, @Sendable () -> Int) {
        let counter = Counter()
        let provider = AWSCLICredentialProvider(
            configuration: .init(profile: profile),
            runner: { _ in
                let index = counter.next()
                return Data(outputs[min(index, outputs.count - 1)].utf8)
            }
        )
        return (provider, { counter.value })
    }

    private func exported(expiration: String?, sessionToken: String? = "TOKEN") -> String {
        var fields = [
            "\"Version\": 1",
            "\"AccessKeyId\": \"AKIAEXAMPLE\"",
            "\"SecretAccessKey\": \"secret\"",
        ]
        if let sessionToken { fields.append("\"SessionToken\": \"\(sessionToken)\"") }
        if let expiration { fields.append("\"Expiration\": \"\(expiration)\"") }
        return "{\(fields.joined(separator: ", "))}"
    }

    @Test("Decodes the credential_process schema")
    func decodesExportedCredentials() async throws {
        let (provider, _) = makeProvider(outputs: [exported(expiration: "2033-11-14T22:13:20Z")])
        let credentials = try await provider.credentials(asOf: Self.now)
        #expect(credentials.accessKeyID == "AKIAEXAMPLE")
        #expect(credentials.secretAccessKey == "secret")
        #expect(credentials.sessionToken == "TOKEN")
        #expect(credentials.expiration == ISO8601DateFormatter().date(from: "2033-11-14T22:13:20Z"))
    }

    @Test("Long-lived keys have no expiry and no session token")
    func longLivedKeys() async throws {
        let (provider, _) = makeProvider(outputs: [exported(expiration: nil, sessionToken: nil)])
        let credentials = try await provider.credentials(asOf: Self.now)
        #expect(credentials.expiration == nil)
        #expect(credentials.sessionToken == nil)
        #expect(credentials.isValid(asOf: Self.now, refreshMargin: 300))
    }

    @Test("Accepts fractional-second expiries too")
    func fractionalSecondExpiry() async throws {
        let (provider, _) = makeProvider(outputs: [exported(expiration: "2033-11-14T22:13:20.123Z")])
        #expect(try await provider.credentials(asOf: Self.now).expiration != nil)
    }

    /// The CLI is a Python program with a real cold start, so it must not be invoked
    /// per request.
    @Test("Caches until the refresh margin")
    func cachesCredentials() async throws {
        let (provider, invocations) = makeProvider(outputs: [exported(expiration: "2033-11-14T22:13:20Z")])
        _ = try await provider.credentials(asOf: Self.now)
        _ = try await provider.credentials(asOf: Self.now)
        _ = try await provider.credentials(asOf: Self.now.addingTimeInterval(60))
        #expect(invocations() == 1)
    }

    @Test("Re-resolves inside the refresh margin")
    func refreshesNearExpiry() async throws {
        let expiry = Self.now.addingTimeInterval(120)
        let formatter = ISO8601DateFormatter()
        let (provider, invocations) = makeProvider(
            outputs: [exported(expiration: formatter.string(from: expiry))]
        )
        _ = try await provider.credentials(asOf: Self.now.addingTimeInterval(-600))
        // Now within the 300s margin of expiry, so the cache must not be reused.
        _ = try await provider.credentials(asOf: Self.now)
        #expect(invocations() == 2)
    }

    @Test("Invalidating forces a fresh resolve")
    func invalidateDropsCache() async throws {
        let (provider, invocations) = makeProvider(outputs: [exported(expiration: "2033-11-14T22:13:20Z")])
        _ = try await provider.credentials(asOf: Self.now)
        await provider.invalidate()
        _ = try await provider.credentials(asOf: Self.now)
        #expect(invocations() == 2)
    }

    /// An expired SSO session is its own diagnosis. Without this it would surface as a
    /// 403 on the first signed request, which points the user at permissions rather
    /// than at `aws sso login`.
    @Test("Already-expired credentials are reported as expired, not returned")
    func expiredCredentialsThrow() async throws {
        let past = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(-60))
        let (provider, _) = makeProvider(profile: "sandbox", outputs: [exported(expiration: past)])
        await #expect(throws: AWSCLIError.credentialsExpired(profile: "sandbox")) {
            _ = try await provider.credentials(asOf: Self.now)
        }
    }

    @Test("Unparseable output is a malformed response")
    func malformedOutputThrows() async throws {
        let (provider, _) = makeProvider(outputs: ["not json at all"])
        await #expect(throws: AWSCLIError.malformedResponse) {
            _ = try await provider.credentials(asOf: Self.now)
        }
    }

    /// A present-but-unparseable expiry must fail rather than be silently treated as
    /// "never expires", which would hand out dead credentials indefinitely.
    @Test("An unreadable expiry is malformed, not treated as permanent")
    func unparseableExpiryThrows() async throws {
        let (provider, _) = makeProvider(outputs: [exported(expiration: "tomorrow-ish")])
        await #expect(throws: AWSCLIError.malformedResponse) {
            _ = try await provider.credentials(asOf: Self.now)
        }
    }
}

/// Invocation counter for the stub runner. The runner is `@Sendable` and called from
/// an actor, so the count needs its own synchronisation.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = count
        count += 1
        return current
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
