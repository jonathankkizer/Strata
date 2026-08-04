import Testing
import Foundation
@testable import Strata

/// Exercises the ARM client against canned JSON served by a URLProtocol stub — no
/// network, no live subscription data. Covers subscription/account decoding,
/// nextLink paging, resource-group extraction, and the HNS flag.
@Suite("Azure management client")
struct AzureManagementClientTests {

    // MARK: - Fixtures

    private struct StubTokenSource: AzureTokenSource {
        func token(asOf now: Date) async throws -> AzureAccessToken {
            AzureAccessToken(accessToken: "fake-token", expiresOn: now.addingTimeInterval(3600), tenant: nil, subscription: nil)
        }
    }

    private func makeClient() -> AzureManagementClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return AzureManagementClient(tokenSource: StubTokenSource(), session: URLSession(configuration: config))
    }

    // MARK: - Subscriptions

    @Test("Lists subscriptions from the ARM value array")
    func listsSubscriptions() async throws {
        let subs = try await makeClient().listSubscriptions()
        #expect(subs.map(\.subscriptionId) == ["sub-1", "sub-2"])
        #expect(subs.first?.displayName == "Sub One")
    }

    // MARK: - Storage accounts

    @Test("Lists a subscription's storage accounts across nextLink pages")
    func listsStorageAccountsWithPaging() async throws {
        let sub = AzureSubscription(subscriptionId: "sub-1", displayName: "Sub One")
        let accounts = try await makeClient().listStorageAccounts(in: sub)
        // page 1 has two accounts, page 2 (via nextLink) has one more
        #expect(accounts.map(\.name) == ["acctone", "accttwo", "acctthree"])

        let one = try #require(accounts.first { $0.name == "acctone" })
        #expect(one.resourceGroup == "rg-alpha")
        #expect(one.location == "eastus")
        #expect(one.isHierarchicalNamespace == true)

        let two = try #require(accounts.first { $0.name == "accttwo" })
        #expect(two.isHierarchicalNamespace == false)
    }

    @Test("Aggregates accounts across all subscriptions, sorted by name")
    func listsAllAccountsSorted() async throws {
        let accounts = try await makeClient().listAllStorageAccounts()
        // sub-1 → acctone/accttwo/acctthree, sub-2 → zzaccount ; sorted by name
        #expect(accounts.map(\.name) == ["acctone", "acctthree", "accttwo", "zzaccount"])
        let zz = try #require(accounts.first { $0.name == "zzaccount" })
        #expect(zz.subscriptionName == "Sub Two")
    }

    // MARK: - nextLink hygiene

    @Test("A nextLink is followed only on the client's own host over https")
    func nextLinkStaysHome() {
        let client = makeClient()
        #expect(client.nextPageURL("https://management.azure.com/subscriptions?_page=2") != nil)
        // The follow-up request carries the management Bearer token, so a link
        // pointing anywhere else must end pagination, not forward the token.
        #expect(client.nextPageURL("https://evil.example.com/subscriptions") == nil)
        #expect(client.nextPageURL("http://management.azure.com/subscriptions") == nil)
        #expect(client.nextPageURL("not a url") == nil)
        #expect(client.nextPageURL(nil) == nil)
    }

    // MARK: - Resource-group extraction

    @Test("Extracts the resource group from an ARM resource ID (case-insensitive)")
    func resourceGroupExtraction() {
        let id = "/subscriptions/sub-1/resourceGroups/rg-alpha/providers/Microsoft.Storage/storageAccounts/acctone"
        #expect(AzureManagementClient.resourceGroup(fromID: id) == "rg-alpha")
        #expect(AzureManagementClient.resourceGroup(fromID: id.lowercased()) == "rg-alpha")
        #expect(AzureManagementClient.resourceGroup(fromID: "/subscriptions/sub-1") == nil)
    }
}

/// Serves deterministic canned ARM JSON keyed purely off the request URL, so it is
/// safe under Swift Testing's parallel execution (no shared mutable state).
private final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Self.body(for: url)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(for url: URL) -> String {
        let path = url.path
        let query = url.query ?? ""

        if path.hasSuffix("/subscriptions") {
            return """
            { "value": [
              { "subscriptionId": "sub-1", "displayName": "Sub One" },
              { "subscriptionId": "sub-2", "displayName": "Sub Two" }
            ] }
            """
        }

        if path.contains("/subscriptions/sub-1/") && path.hasSuffix("/storageAccounts") {
            if query.contains("_page=2") {
                return account(name: "acctthree", sub: "sub-1", rg: "rg-gamma", location: "westus", hns: false)
            }
            let base = "https://management.azure.com/subscriptions/sub-1/providers/Microsoft.Storage/storageAccounts?api-version=2023-01-01&_page=2"
            return """
            { "value": [
              \(accountObject(name: "acctone", sub: "sub-1", rg: "rg-alpha", location: "eastus", hns: true)),
              \(accountObject(name: "accttwo", sub: "sub-1", rg: "rg-beta", location: "eastus", hns: false))
            ], "nextLink": "\(base)" }
            """
        }

        if path.contains("/subscriptions/sub-2/") && path.hasSuffix("/storageAccounts") {
            return account(name: "zzaccount", sub: "sub-2", rg: "rg-delta", location: "centralus", hns: false)
        }

        return "{ \"value\": [] }"
    }

    private static func account(name: String, sub: String, rg: String, location: String, hns: Bool) -> String {
        "{ \"value\": [ \(accountObject(name: name, sub: sub, rg: rg, location: location, hns: hns)) ] }"
    }

    private static func accountObject(name: String, sub: String, rg: String, location: String, hns: Bool) -> String {
        """
        { "id": "/subscriptions/\(sub)/resourceGroups/\(rg)/providers/Microsoft.Storage/storageAccounts/\(name)",
          "name": "\(name)", "location": "\(location)",
          "properties": { "isHnsEnabled": \(hns) } }
        """
    }
}
