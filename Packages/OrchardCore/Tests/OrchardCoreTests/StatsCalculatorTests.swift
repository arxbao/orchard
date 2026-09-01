import Testing
@testable import OrchardCore

/// Unit tests for the CPU%/I/O-rate differential math extracted from davit's
/// AppState.refreshStats() into the pure `StatsCalculator`.
struct StatsCalculatorTests {
    @Test func cpuPercentFromDelta() {
        // 1 second apart, 50% of one core: 0.5 * 1_000_000 usec consumed.
        let d = StatsCalculator.delta(cpuUsec: 500_000, blockRead: 0, blockWrite: 0, dt: 1.0)
        #expect(d?.cpuPercent == 50.0)
    }

    @Test func subSecondDeltaRejected() {
        // davit ignores deltas under 0.1s (too noisy).
        #expect(StatsCalculator.delta(cpuUsec: 100, blockRead: 0, blockWrite: 0, dt: 0.05) == nil)
    }

    @Test func byteRates() {
        let d = StatsCalculator.delta(cpuUsec: 0, blockRead: 1_048_576, blockWrite: 2_097_152, dt: 1.0)
        #expect(d?.diskReadRate == 1_048_576)
        #expect(d?.diskWriteRate == 2_097_152)
    }
}
