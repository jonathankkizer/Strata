import Testing
import Foundation
@testable import Strata

@Suite("ProviderAccount")
struct ProviderAccountTests {

    @Test("Identity spans the provider, not just the name")
    func identityIncludesProvider() {
        #expect(ProviderAccount.azure("prod") != ProviderAccount.s3(profile: "prod"))
        #expect(ProviderAccount.azure("prod").id != ProviderAccount.s3(profile: "prod").id)
        #expect(ProviderAccount.azure("prod") == ProviderAccount.azure("prod"))
    }

    /// Raw values are persisted, so they have to be slugs rather than the display
    /// strings they used to be — renaming a product must not orphan saved places.
    @Test("Provider kinds encode as stable slugs")
    func kindRawValuesAreStableSlugs() {
        #expect(ProviderKind.s3.rawValue == "s3")
        #expect(ProviderKind.azureBlob.rawValue == "azureBlob")
        #expect(ProviderKind.s3.displayName == "Amazon S3")
        #expect(ProviderKind.azureBlob.displayName == "Azure Blob Storage")
    }

    @Test("Each provider is described in its own vocabulary")
    func containerNounPerProvider() {
        #expect(ProviderKind.s3.containerNoun == "bucket")
        #expect(ProviderKind.azureBlob.containerNoun == "container")
    }

    @Test("Round-trips through Codable")
    func roundTrips() throws {
        for account in [ProviderAccount.azure("acct"), .s3(profile: "default")] {
            let data = try JSONEncoder().encode(account)
            #expect(try JSONDecoder().decode(ProviderAccount.self, from: data) == account)
        }
    }
}

/// The riskiest part of introducing `ProviderAccount`: favorites are already on disk
/// with `account` as a bare string. `FavoritesStore.load` decodes the whole array with
/// `try?`, so a single entry that fails to decode silently takes *every* saved place
/// with it. These tests pin the tolerant decode that prevents that.
@Suite("Favorite migration from pre-S3 storage")
struct FavoriteMigrationTests {

    private func decode(_ json: String) throws -> [Favorite] {
        try JSONDecoder().decode([Favorite].self, from: Data(json.utf8))
    }

    @Test("A legacy string account decodes as Azure")
    func legacyStringBecomesAzure() throws {
        let id = UUID()
        let favorites = try decode("""
            [{
              "id": "\(id.uuidString)",
              "account": "dlssvhstorage",
              "container": "data",
              "prefix": "raw/2026/",
              "customName": "Landing zone"
            }]
            """)

        let favorite = try #require(favorites.first)
        #expect(favorite.id == id)
        #expect(favorite.account == .azure("dlssvhstorage"))
        #expect(favorite.container == "data")
        #expect(favorite.prefix == "raw/2026/")
        #expect(favorite.customName == "Landing zone")
    }

    @Test("A legacy entry with no custom name still decodes")
    func legacyWithoutCustomName() throws {
        let favorites = try decode("""
            [{
              "id": "\(UUID().uuidString)",
              "account": "acct",
              "container": "data",
              "prefix": ""
            }]
            """)
        #expect(favorites.count == 1)
        #expect(favorites.first?.account == .azure("acct"))
        #expect(favorites.first?.customName == nil)
    }

    @Test("New-format entries decode as themselves")
    func newFormatDecodes() throws {
        let favorites = try decode("""
            [{
              "id": "\(UUID().uuidString)",
              "account": { "kind": "s3", "name": "default" },
              "container": "my-bucket",
              "prefix": "logs/"
            }]
            """)
        #expect(favorites.first?.account == .s3(profile: "default"))
    }

    /// The realistic upgrade: a list written before the change, read after it.
    @Test("A mixed list decodes entry by entry without losing any")
    func mixedListSurvives() throws {
        let favorites = try decode("""
            [
              { "id": "\(UUID().uuidString)", "account": "legacy", "container": "a", "prefix": "" },
              { "id": "\(UUID().uuidString)", "account": { "kind": "s3", "name": "new" }, "container": "b", "prefix": "x/" }
            ]
            """)
        #expect(favorites.count == 2)
        #expect(favorites.map(\.account) == [.azure("legacy"), .s3(profile: "new")])
    }

    @Test("Encoding a migrated favorite produces the new shape")
    func reEncodesInNewFormat() throws {
        let original = try #require(try decode("""
            [{ "id": "\(UUID().uuidString)", "account": "acct", "container": "data", "prefix": "" }]
            """).first)

        let round = try JSONDecoder().decode(Favorite.self, from: JSONEncoder().encode(original))
        #expect(round.account == .azure("acct"))
        #expect(round == original)
    }

    /// Genuinely corrupt input must still fail, or the tolerant path would be hiding
    /// real problems rather than migrating old ones.
    @Test("Structurally invalid entries still throw")
    func invalidStillThrows() {
        #expect(throws: (any Error).self) {
            _ = try decode("""
                [{ "id": "not-a-uuid", "account": "acct", "container": "data", "prefix": "" }]
                """)
        }
        #expect(throws: (any Error).self) {
            _ = try decode("""
                [{ "id": "\(UUID().uuidString)", "container": "data", "prefix": "" }]
                """)
        }
    }
}

/// `.serialized` is load-bearing: `StrataDefaults` reads `.standard`, so every test
/// here manipulates the *same* two keys. Swift Testing runs tests within a suite in
/// parallel by default, which would let them interleave on shared state and pass or
/// fail depending on timing.
@Suite("Last-account preference migration", .serialized)
@MainActor
struct LastAccountMigrationTests {

    /// `StrataDefaults` reads `.standard`, so these drive the migration through the
    /// same keys it uses and clean up after themselves rather than leaving state
    /// behind in the real domain.
    private func withCleanKeys(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let legacy = defaults.object(forKey: "LastAccount")
        let current = defaults.object(forKey: "LastProviderAccount")
        defaults.removeObject(forKey: "LastAccount")
        defaults.removeObject(forKey: "LastProviderAccount")

        body()

        defaults.removeObject(forKey: "LastAccount")
        defaults.removeObject(forKey: "LastProviderAccount")
        if let legacy { defaults.set(legacy, forKey: "LastAccount") }
        if let current { defaults.set(current, forKey: "LastProviderAccount") }
    }

    @Test("A pre-S3 bare account name reads back as Azure")
    func legacyKeyMigrates() {
        withCleanKeys {
            UserDefaults.standard.set("dlssvhstorage", forKey: "LastAccount")
            #expect(StrataDefaults.lastAccount == .azure("dlssvhstorage"))
        }
    }

    @Test("An empty legacy value is no account, not an empty one")
    func emptyLegacyIsNil() {
        withCleanKeys {
            UserDefaults.standard.set("", forKey: "LastAccount")
            #expect(StrataDefaults.lastAccount == nil)
        }
    }

    @Test("Writing supersedes the legacy value so it can't come back")
    func writeClearsLegacy() {
        withCleanKeys {
            UserDefaults.standard.set("old-azure", forKey: "LastAccount")
            StrataDefaults.lastAccount = .s3(profile: "default")
            #expect(StrataDefaults.lastAccount == .s3(profile: "default"))
            #expect(UserDefaults.standard.string(forKey: "LastAccount") == nil)
        }
    }

    @Test("Clearing removes both keys")
    func clearingRemovesBoth() {
        withCleanKeys {
            StrataDefaults.lastAccount = .azure("acct")
            StrataDefaults.lastAccount = nil
            #expect(StrataDefaults.lastAccount == nil)
        }
    }

    @Test("Round-trips an S3 profile")
    func roundTripsS3() {
        withCleanKeys {
            StrataDefaults.lastAccount = .s3(profile: "sandbox")
            #expect(StrataDefaults.lastAccount == .s3(profile: "sandbox"))
        }
    }
}
