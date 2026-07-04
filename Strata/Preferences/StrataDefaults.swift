import Foundation

/// App-wide user preferences, UserDefaults-backed.
enum StrataDefaults {

    private static let askBeforeUploadingKey = "AskBeforeUploading"

    /// When true, uploads show a confirmation sheet listing each file's predicted
    /// event before starting. Off by default: drops and Upload… begin immediately,
    /// and predictions surface as badges in the Transfers popover.
    static var askBeforeUploading: Bool {
        get { UserDefaults.standard.bool(forKey: askBeforeUploadingKey) }
        set { UserDefaults.standard.set(newValue, forKey: askBeforeUploadingKey) }
    }
}
