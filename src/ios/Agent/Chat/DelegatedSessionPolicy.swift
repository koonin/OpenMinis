import Foundation

/// Small, dependency-free policy shared by persistence/UI and the worker
/// runtime. Keeping these rules in one place prevents an internal worker from
/// accidentally becoming a top-level chat or outliving its browser budget.
enum DelegatedSessionPolicy {
    static let sessionSource = "delegated_worker"

    static func isUserFacing(source: String?) -> Bool {
        source != sessionSource
    }

    /// Leave enough of the worker's total deadline to try another source and
    /// synthesize an answer. The public worker minimum is 10 seconds.
    static func browserActionDeadTimeout(totalTimeoutSeconds: Int) -> TimeInterval {
        min(60, max(3, TimeInterval(totalTimeoutSeconds) / 2))
    }
}
