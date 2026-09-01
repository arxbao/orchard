import Foundation

/// Pure differential math for live stats, extracted from davit's
/// `AppState.refreshStats()` (AppState.swift:309–324) so the GUI and CLI can
/// share it and unit tests can exercise it without a daemon or timers.
///
/// Callers pass the *delta* between two samples (current minus previous);
/// this type only turns deltas + elapsed time into rates.
public enum StatsCalculator {
    public struct Delta {
        public let cpuPercent: Double
        public let diskReadRate: Double
        public let diskWriteRate: Double

        public init(cpuPercent: Double, diskReadRate: Double, diskWriteRate: Double) {
            self.cpuPercent = cpuPercent
            self.diskReadRate = diskReadRate
            self.diskWriteRate = diskWriteRate
        }
    }

    /// `dt` is the elapsed time between the two samples. Returns nil when the
    /// delta is too small to be meaningful (davit ignores dt <= 0.1s — the
    /// 2s poll produces far larger gaps; a tiny dt makes rates explode).
    public static func delta(cpuUsec: Int64, blockRead: Int64, blockWrite: Int64, dt: TimeInterval) -> Delta? {
        guard dt > 0.1 else { return nil }
        return Delta(
            cpuPercent: Double(max(0, cpuUsec)) / (dt * 1_000_000) * 100.0,
            diskReadRate: Double(max(0, blockRead)) / dt,
            diskWriteRate: Double(max(0, blockWrite)) / dt
        )
    }
}
