import Foundation

/// Shared latency presentation for node ping results: negative or
/// over-threshold values render as "Timeout". Keep the threshold in sync
/// with `PingBadgeView`'s default `timeoutThreshold`.
enum LatencyFormat {
    static let timeoutThreshold: Double = 2_000

    static func isTimeout(_ milliseconds: Double?) -> Bool {
        guard let milliseconds else { return true }
        return milliseconds < 0 || milliseconds > timeoutThreshold
    }

    static func label(_ milliseconds: Double?) -> String {
        guard !isTimeout(milliseconds), let milliseconds else { return "Timeout" }
        return "\(Int(milliseconds.rounded())) ms"
    }

    static func parts(_ milliseconds: Double?) -> (value: String, unit: String) {
        guard !isTimeout(milliseconds), let milliseconds else { return ("Timeout", "") }
        return ("\(Int(milliseconds.rounded()))", "ms")
    }
}
