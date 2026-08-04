import Foundation

/// Builds the concrete provider for an account. The one place in the app that knows
/// which types back which cloud — everything else holds an `any StorageProvider`.
///
/// Before this existed, `BrowserSplitViewController.connect` constructed
/// `AzureStorageEndpoint` + `AzureBlobProvider` + `AzureCLITokenProvider` inline,
/// which meant the browse surface could only ever talk to Azure.
enum ProviderFactory {

    static func make(for account: ProviderAccount) -> any StorageProvider {
        switch account.kind {
        case .azureBlob:
            return AzureBlobProvider(
                displayName: account.name,
                endpoint: AzureStorageEndpoint(account: account.name),
                tokenSource: AzureCLITokenProvider()
            )
        case .s3:
            return S3Provider(displayName: account.name)
        }
    }
}
