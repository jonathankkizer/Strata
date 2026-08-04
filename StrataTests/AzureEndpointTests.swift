import Testing
import Foundation
@testable import Strata

@Suite("Azure storage endpoint")
struct AzureEndpointTests {

    @Test("Account-name validation follows Azure's naming rules")
    func accountNameValidation() {
        #expect(AzureStorageEndpoint.isValidAccountName("mystorageacct"))
        #expect(AzureStorageEndpoint.isValidAccountName("abc"))
        #expect(AzureStorageEndpoint.isValidAccountName("acct123"))
        #expect(AzureStorageEndpoint.isValidAccountName(String(repeating: "a", count: 24)))

        #expect(AzureStorageEndpoint.isValidAccountName("") == false)
        #expect(AzureStorageEndpoint.isValidAccountName("ab") == false)
        #expect(AzureStorageEndpoint.isValidAccountName(String(repeating: "a", count: 25)) == false)
        #expect(AzureStorageEndpoint.isValidAccountName("Upper") == false)
        #expect(AzureStorageEndpoint.isValidAccountName("with-dash") == false)
        #expect(AzureStorageEndpoint.isValidAccountName("with.dot") == false)
        #expect(AzureStorageEndpoint.isValidAccountName("has space") == false)
        // The ones that matter: names that would change the request's host.
        #expect(AzureStorageEndpoint.isValidAccountName("evil.com/x") == false)
        #expect(AzureStorageEndpoint.isValidAccountName("a/b") == false)
        #expect(AzureStorageEndpoint.isValidAccountName("acct:8080") == false)
        #expect(AzureStorageEndpoint.isValidAccountName("acct@host") == false)
        // Non-ASCII lowercase letters and digits are not hostname-safe either.
        #expect(AzureStorageEndpoint.isValidAccountName("acctü") == false)
        #expect(AzureStorageEndpoint.isValidAccountName("acct١٢٣") == false)
    }

    @Test("A valid account name lands in host position")
    func baseURLHost() {
        let endpoint = AzureStorageEndpoint(account: "mystorageacct")
        #expect(endpoint.baseURL.absoluteString == "https://mystorageacct.blob.core.windows.net")
        #expect(endpoint.baseURL.host == "mystorageacct.blob.core.windows.net")
    }
}
