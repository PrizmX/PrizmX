import Foundation
import SwiftUI

/// Shared latency presentation for node ping results: negative or
/// over-threshold values render as "Timeout". Keep the thresholds in sync
/// with `PingBadgeView`'s defaults.
enum LatencyFormat {
    static let goodThreshold: Double = 100
    static let fairThreshold: Double = 300
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

    /// Green < 100ms, yellow < 300ms, red for slow or timeout.
    static func color(_ milliseconds: Double?) -> Color {
        guard !isTimeout(milliseconds), let milliseconds else { return .red }
        if milliseconds < goodThreshold { return .green }
        if milliseconds < fairThreshold { return .yellow }
        return .red
    }
}
