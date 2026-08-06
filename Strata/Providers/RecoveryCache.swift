import Foundation

/// Remembers whether a delete in a given scope can be undone.
///
/// The answer costs an extra round trip and a permission the user may not have, and the
/// confirmation sheet it feeds has to appear the moment the user asks to delete
/// something. Failures are cached too, deliberately: re-asking on every confirmation
/// would add latency for a question the account has already refused to answer.
///
/// The scope is whatever the setting belongs to — the whole account on Azure, where
/// retention is a service property, and one bucket on S3, where versioning is per-bucket.
actor RecoveryCache {

    private var byScope: [String: DeletionRecovery] = [:]

    func value(
        for scope: String = "",
        _ load: @Sendable () async throws -> DeletionRecovery
    ) async -> DeletionRecovery {
        if let known = byScope[scope] { return known }
        // A policy that can't be read is `.unknown`, never an error: not knowing whether
        // a delete is reversible is a thing to tell the user, not a reason to stop them.
        let result = (try? await load()) ?? .unknown
        byScope[scope] = result
        return result
    }
}
