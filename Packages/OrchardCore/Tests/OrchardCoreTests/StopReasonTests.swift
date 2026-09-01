import Testing
@testable import OrchardCore

/// Unit tests for the pure kernel/stdio log scanners in `StopReasonParser`.
/// These never touch a daemon — captured log lines only.
struct StopReasonTests {
    @Test func oomDetection() {
        let kernel = [
            "Killed process 109 (docling-serve), UID 0, ...",
            "Memory cgroup out of memory: Killed process 42 (app) ...",
        ]
        let reason = StopReasonParser.stopReason(fromKernelLines: kernel)
        guard case .outOfMemory(let process) = reason else {
            Issue.record("expected .outOfMemory, got \(String(describing: reason))")
            return
        }
        #expect(process == "app")
    }

    @Test func rosettaDetectionWinsOverKernel() {
        let stdio = ["... rosetta error: unhandled auxiliary vector type 29 ..."]
        let kernel = ["Memory cgroup out of memory: Killed process 7 (x) ..."]
        let reason = StopReasonParser.stopReason(fromStdioLines: stdio, kernelLines: kernel)
        guard case .rosettaIncompatible(let vectorType) = reason else {
            Issue.record("expected .rosettaIncompatible, got \(String(describing: reason))")
            return
        }
        #expect(vectorType == "29")
    }

    @Test func noMatchReturnsNil() {
        #expect(StopReasonParser.stopReason(fromStdioLines: ["hello"], kernelLines: ["boot ok"]) == nil)
    }
}
