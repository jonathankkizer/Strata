import Foundation

/// A failure worth trying again: the service said it was busy or broke, or the network
/// dropped. Carries the error to report if the retries run out, and how long the
/// service asked us to wait, when it said.
struct TransientFailure: Error, Sendable {
    let underlying: any Error
    let retryAfter: Duration?
}

/// When to try a request again, and how long to wait first.
///
/// Both clouds ask clients to do this — S3 answers load with 503 `SlowDown`, Azure
/// with 503 `ServerBusy` — and a laptop's network drops on sleep and Wi-Fi changes.
/// Without it, one blip at part 4,000 of a 50 GB upload failed the whole transfer.
/// Retries are per request, so the parts already sent stay sent.
///
/// Pure policy, no networking, so the decisions are testable.
struct RetryPolicy: Sendable {
    /// Tries in total, including the first.
    var maxAttempts = 5
    var baseDelay: Duration = .milliseconds(500)
    var maxDelay: Duration = .seconds(20)

    static let standard = RetryPolicy()

    /// HTTP statuses that mean "not now" rather than "no".
    static func isTransient(status: Int) -> Bool {
        [408, 429, 500, 502, 503, 504].contains(status)
    }

    /// Network failures that a later attempt can plausibly get past. Cancellation is
    /// deliberately absent: that's the user pressing Stop.
    static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// `Retry-After` in its seconds form. The HTTP-date form is rare from these
    /// services and falls back to ordinary backoff.
    static func retryAfter(from response: HTTPURLResponse) -> Duration? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Int(value.trimmingCharacters(in: .whitespaces)), seconds >= 0 else { return nil }
        return .seconds(seconds)
    }

    /// How long to wait before attempt `attempt + 1` (attempts count from 1).
    /// Exponential with full jitter — a random wait up to the exponential bound — so
    /// many transfers failing together don't all come back at the same instant. A
    /// service's own `Retry-After` wins, capped so a bad header can't stall a
    /// transfer for an hour.
    func delay(afterAttempt attempt: Int, retryAfter: Duration?, random: Double) -> Duration {
        if let retryAfter { return min(retryAfter, maxDelay) }
        let exponent = min(max(attempt - 1, 0), 16)
        let bound = min(baseDelay * (1 << exponent), maxDelay)
        return bound * min(max(random, 0), 1)
    }

    /// Runs `operation`, retrying transient failures. Anything else, including
    /// cancellation, is thrown straight away; so is the last transient failure's
    /// underlying error once the attempts run out.
    func run<T>(
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        random: @Sendable () -> Double = { Double.random(in: 0...1) },
        _ operation: () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            let failure: TransientFailure
            do {
                return try await operation()
            } catch let transient as TransientFailure {
                failure = transient
            } catch let error as URLError where Self.isTransient(error) {
                failure = TransientFailure(underlying: error, retryAfter: nil)
            }
            guard attempt < maxAttempts else { throw failure.underlying }
            try await sleep(delay(afterAttempt: attempt, retryAfter: failure.retryAfter, random: random()))
            attempt += 1
        }
    }
}
