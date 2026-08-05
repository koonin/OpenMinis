import Foundation

/// Pure, fail-closed policy helpers for deciding whether a stale launch marker
/// represents an app that was explicitly idle when it entered the background.
///
/// A retained `WKWebView` is only a cache entry. It is active work only while a
/// browser action owns it or while WebKit is still loading it.
enum StaleMarkerClassifier {
    static func browserWasExplicitlyIdle(
        totalTabs: Int?,
        tabs: [[String: Any]]?,
        inflightActionCount: Int?
    ) -> Bool {
        guard let totalTabs,
              totalTabs >= 0,
              let tabs,
              tabs.count == totalTabs,
              inflightActionCount == 0
        else {
            return false
        }

        return tabs.allSatisfy { tab in
            guard let inUse = tab["inUse"] as? Bool,
                  let isLoading = tab["isLoading"] as? Bool
            else {
                return false
            }
            return !inUse && !isLoading
        }
    }
}
