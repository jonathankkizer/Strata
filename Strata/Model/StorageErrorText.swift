import Foundation

/// What to tell someone when a storage operation fails.
///
/// One place, because the same failure used to be worded five different ways across
/// the list, the columns, the transfer rows, the connect path and the picker, and an
/// S3 "access denied" was being explained as a missing Azure role. The wording depends
/// on the cloud, so the caller says which one it was talking to. No AppKit, so it's
/// testable.
enum StorageErrorText {

    /// A headline and, where there's something to do about it, what to do.
    struct Message: Equatable {
        var summary: String
        var suggestion: String?

        /// Both, as a paragraph pair for a message view.
        var full: String {
            suggestion.map { "\(summary)\n\n\($0)" } ?? summary
        }
    }

    static func message(for error: any Error, kind: ProviderKind) -> Message {
        switch error {
        case StorageProviderError.dataPlaneForbidden(let account):
            switch kind {
            case .azureBlob:
                return Message(
                    summary: "This sign-in can\u{2019}t read blob data in \u{201C}\(account)\u{201D}.",
                    suggestion: "It needs the Storage Blob Data Reader or Contributor role. Owner, Contributor and Reader on the account don\u{2019}t include access to the data itself."
                )
            case .s3:
                return Message(
                    summary: "Access to \u{201C}\(account)\u{201D} was denied.",
                    suggestion: "Check the IAM policy for this profile and the bucket\u{2019}s own policy."
                )
            }
        case StorageProviderError.unauthorized:
            switch kind {
            case .azureBlob:
                return Message(
                    summary: "Azure didn\u{2019}t accept this sign-in.",
                    suggestion: "Run \u{201C}az login\u{201D} in Terminal, using an account in the storage account\u{2019}s tenant, then try again."
                )
            case .s3:
                return Message(
                    summary: "AWS didn\u{2019}t accept this profile\u{2019}s credentials.",
                    suggestion: "If it\u{2019}s an SSO profile, run \u{201C}aws sso login\u{201D} in Terminal. Otherwise check the keys in ~/.aws/credentials."
                )
            }
        case StorageProviderError.networkRestricted(let account):
            return Message(
                summary: "\u{201C}\(account)\u{201D} turned this request away.",
                suggestion: "The storage account\u{2019}s firewall or private-endpoint settings probably don\u{2019}t allow this network."
            )
        case StorageProviderError.clockSkewed:
            return Message(
                summary: "This Mac\u{2019}s clock is too far off for the request to be accepted.",
                suggestion: "Turn on \u{201C}Set time and date automatically\u{201D} in System Settings \u{25B8} General \u{25B8} Date & Time."
            )
        case StorageProviderError.notImplemented:
            return Message(summary: "\(kind.displayName) can\u{2019}t do that yet.", suggestion: nil)
        case let error as LocalizedError:
            return Message(
                summary: error.errorDescription ?? error.localizedDescription,
                suggestion: error.recoverySuggestion
            )
        default:
            return Message(summary: error.localizedDescription, suggestion: nil)
        }
    }

    /// One short line, for a column or a transfer row where there's no room for advice.
    static func summary(for error: any Error, kind: ProviderKind) -> String {
        message(for: error, kind: kind).summary
    }
}
