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
            // The profile's own `region` is the starting point; buckets living
            // elsewhere are discovered and remembered by the provider on first use.
            let profile = AWSConfigFile.profilesOnDisk().first { $0.name == account.name }
            return S3Provider(
                profile: account.name,
                region: profile?.region ?? "us-east-1"
            )
        }
    }
}
