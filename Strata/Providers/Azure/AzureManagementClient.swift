import Foundation

/// A subscription visible to the signed-in identity.
struct AzureSubscription: Sendable, Hashable, Identifiable {
    var id: String { subscriptionId }
    var subscriptionId: String
    var displayName: String
}

/// A storage account discovered via the management plane, with enough context to
/// connect to its data plane and to predict events (the HNS flag decides DFS
/// `FlushWithClose` vs flat `PutBlockList`).
struct StorageAccountRef: Sendable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var resourceGroup: String
    var location: String
    var subscriptionId: String
    var subscriptionName: String
    var isHierarchicalNamespace: Bool
}

enum AzureManagementError: Error, Sendable {
    case notHTTPResponse
    /// A valid token, but the identity can't read management resources (no reader
    /// role at the subscription/tenant). Distinct from the data-plane 403.
    case managementForbidden
    case unauthorized
    case httpError(status: Int, message: String)
    case malformedResponse
}

/// Reads the Azure Resource Manager (ARM) API to enumerate subscriptions and
/// storage accounts, so the user can pick an account from a list instead of
/// typing its name. Read-only: the app never mutates management resources.
///
/// This is a different audience than the blob data plane — it needs a token minted
/// for `AzureAuth.managementResource`, so callers pass a management-scoped
/// `AzureTokenSource` (an `AzureCLITokenProvider` configured with that resource).
struct AzureManagementClient: Sendable {

    let tokenSource: any AzureTokenSource
    let session: URLSession
    /// Overridable for sovereign clouds.
    let baseURL: URL

    private static let subscriptionsAPIVersion = "2020-01-01"
    private static let storageAPIVersion = "2023-01-01"
    /// Backstop against an endless nextLink loop.
    private static let maxPages = 1000

    init(
        tokenSource: any AzureTokenSource,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://management.azure.com")!
    ) {
        self.tokenSource = tokenSource
        self.session = session
        self.baseURL = baseURL
    }

    // MARK: - Subscriptions

    /// Every subscription the identity can see.
    func listSubscriptions() async throws -> [AzureSubscription] {
        var url: URL? = baseURL
            .appendingPathComponent("subscriptions")
            .appending(queryItems: [URLQueryItem(name: "api-version", value: Self.subscriptionsAPIVersion)])

        var results: [AzureSubscription] = []
        var page = 0
        while let next = url, page < Self.maxPages {
            let data = try await get(next)
            let decoded = try Self.decode(SubscriptionListResponse.self, from: data)
            results.append(contentsOf: decoded.value.map {
                AzureSubscription(subscriptionId: $0.subscriptionId, displayName: $0.displayName ?? $0.subscriptionId)
            })
            url = decoded.nextLink.flatMap(URL.init(string:))
            page += 1
        }
        return results
    }

    // MARK: - Storage accounts

    /// Storage accounts within one subscription.
    func listStorageAccounts(in subscription: AzureSubscription) async throws -> [StorageAccountRef] {
        var url: URL? = baseURL
            .appendingPathComponent("subscriptions/\(subscription.subscriptionId)/providers/Microsoft.Storage/storageAccounts")
            .appending(queryItems: [URLQueryItem(name: "api-version", value: Self.storageAPIVersion)])

        var results: [StorageAccountRef] = []
        var page = 0
        while let next = url, page < Self.maxPages {
            let data = try await get(next)
            let decoded = try Self.decode(StorageAccountListResponse.self, from: data)
            for item in decoded.value {
                results.append(StorageAccountRef(
                    name: item.name,
                    resourceGroup: Self.resourceGroup(fromID: item.id) ?? "",
                    location: item.location ?? "",
                    subscriptionId: subscription.subscriptionId,
                    subscriptionName: subscription.displayName,
                    isHierarchicalNamespace: item.properties?.isHnsEnabled ?? false
                ))
            }
            url = decoded.nextLink.flatMap(URL.init(string:))
            page += 1
        }
        return results
    }

    /// Every storage account across every visible subscription, enumerated
    /// concurrently. A subscription the identity can't read is skipped rather than
    /// failing the whole listing.
    func listAllStorageAccounts() async throws -> [StorageAccountRef] {
        let subscriptions = try await listSubscriptions()

        let accounts = try await withThrowingTaskGroup(of: [StorageAccountRef].self) { group in
            for subscription in subscriptions {
                group.addTask {
                    (try? await listStorageAccounts(in: subscription)) ?? []
                }
            }
            var all: [StorageAccountRef] = []
            for try await batch in group {
                all.append(contentsOf: batch)
            }
            return all
        }

        return accounts.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Transport

    private func get(_ url: URL) async throws -> Data {
        let token = try await tokenSource.token(asOf: Date())
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AzureManagementError.notHTTPResponse
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw AzureManagementError.unauthorized
        case 403:
            throw AzureManagementError.managementForbidden
        default:
            let message = String(data: data, encoding: .utf8) ?? ""
            throw AzureManagementError.httpError(status: http.statusCode, message: message)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch is DecodingError {
            throw AzureManagementError.malformedResponse
        }
    }

    /// Pulls the resource group out of an ARM resource ID:
    /// `/subscriptions/{sub}/resourceGroups/{rg}/providers/…`. Case-insensitive on
    /// the segment name, as ARM IDs vary.
    static func resourceGroup(fromID id: String) -> String? {
        let parts = id.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let index = parts.firstIndex(where: { $0.caseInsensitiveCompare("resourceGroups") == .orderedSame }),
              index + 1 < parts.count else { return nil }
        return parts[index + 1]
    }
}

// MARK: - ARM JSON shapes
//
// ARM list endpoints wrap results in `{ "value": [...], "nextLink": "..." }`.

private struct SubscriptionListResponse: Decodable {
    let value: [Subscription]
    let nextLink: String?

    struct Subscription: Decodable {
        let subscriptionId: String
        let displayName: String?
    }
}

private struct StorageAccountListResponse: Decodable {
    let value: [Account]
    let nextLink: String?

    struct Account: Decodable {
        let id: String
        let name: String
        let location: String?
        let properties: Properties?

        struct Properties: Decodable {
            let isHnsEnabled: Bool?
        }
    }
}
