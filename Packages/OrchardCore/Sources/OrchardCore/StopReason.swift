import Foundation

// MARK: - Stop reason (why did a container die?)

/// A best-effort explanation for why a container stopped, read from the VM's
/// kernel (boot) log. Only OOM is detected today; the enum leaves room to grow.
/// Ported from davit (Backend.swift), made `public`.
public enum StopReason: Equatable, Hashable {
    /// The Linux OOM killer terminated a process because the container hit its
    /// own `--memory` limit (memory cgroup OOM, not host RAM exhaustion).
    /// `process` is the killed process name when the kernel logged it.
    case outOfMemory(process: String?)
    /// An amd64 image failed under Rosetta with an "unhandled auxiliary vector
    /// type" error — Rosetta is present but too old (the macOS it shipped with
    /// predates the aux-vector entry the guest passes). `vectorType` is the
    /// numeric type from the message (e.g. "29" = AT_HWCAP3) when present.
    case rosettaIncompatible(vectorType: String?)

    public var isOOM: Bool { if case .outOfMemory = self { return true }; return false }
}

/// Pure log scanning for `StopReason`, split out of the service layer so it is
/// unit-testable with captured log lines (no daemon, no file handles).
/// davit kept these as `extension ContainerService` statics; the GUI's async
/// `ContainerService.stopReason(_ id:)` (which reads the actual log handles)
/// delegates to these when it lands in the app layer.
public enum StopReasonParser {
    /// Pure log scan over both streams: a Rosetta-too-old failure in the
    /// process (stdio) log, or an out-of-memory kill in the kernel (boot) log.
    /// Returns nil when neither is recognizable.
    public static func stopReason(fromStdioLines stdio: [String], kernelLines kernel: [String]) -> StopReason? {
        // Rosetta refusing the binary happens at exec, before the process can
        // do anything else, so it wins over any later signal.
        for line in stdio.reversed()
        where line.contains("rosetta error") && line.contains("auxiliary vector") {
            return .rosettaIncompatible(vectorType: auxVectorType(in: line))
        }
        return stopReason(fromKernelLines: kernel)
    }

    /// Pull the numeric aux-vector type out of "unhandled auxiliary vector type 29".
    static func auxVectorType(in line: String) -> String? {
        guard let r = line.range(of: "auxiliary vector type ") else { return nil }
        let digits = line[r.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    /// Pure kernel-log scan. Scans newest-first: the last OOM is the one that
    /// killed the container. Matches a memory-cgroup OOM (the container's own
    /// `--memory` limit), not host-RAM exhaustion.
    public static func stopReason(fromKernelLines lines: [String]) -> StopReason? {
        for line in lines.reversed() {
            let isMemcgOOM = line.contains("Memory cgroup out of memory")
                || (line.contains("oom-kill:") && line.contains("CONSTRAINT_MEMCG"))
            guard isMemcgOOM else { continue }
            return .outOfMemory(process: killedProcessName(in: line))
        }
        return nil
    }

    /// Pull the process name out of a kernel OOM line, from either
    /// "Killed process 109 (docling-serve)" or "...,task=docling-serve,...".
    static func killedProcessName(in line: String) -> String? {
        if let open = line.range(of: "Killed process "),
           let paren = line.range(of: "(", range: open.upperBound..<line.endIndex),
           let close = line.range(of: ")", range: paren.upperBound..<line.endIndex) {
            return String(line[paren.upperBound..<close.lowerBound])
        }
        if let r = line.range(of: "task=") {
            let rest = line[r.upperBound...]
            let name = rest.prefix { $0 != "," && $0 != " " }
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }
}
