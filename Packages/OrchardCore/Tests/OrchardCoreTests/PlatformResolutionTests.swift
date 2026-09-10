import Testing
@testable import OrchardCore

/// Unit tests for platform-install resolution (davit fix #20): version parsing
/// and the pure `choose(from:)` picker. davit shipped this logic untested; the
/// compatibility matrix is exactly the kind of thing that regresses silently.
struct PlatformResolutionTests {
    private func binary(_ root: String, _ version: PlatformVersion?) -> ResolvedBinary {
        ResolvedBinary(installRoot: root, apiserverPath: "\(root)/bin/container-apiserver",
                       source: .system, version: version)
    }

    @Test func parsesBareVersion() {
        #expect(PlatformVersion("1.3.1") == PlatformVersion(1, 3, 1))
        #expect(PlatformVersion("0.5.0") == PlatformVersion(0, 5, 0))
        // Two components is enough; patch defaults to 0.
        #expect(PlatformVersion("1.3") == PlatformVersion(1, 3, 0))
    }

    @Test func parsesFullVersionLine() {
        let line = "container-apiserver version 1.3.1 (build: release, commit: a9a62e2)"
        #expect(PlatformVersion(line) == PlatformVersion(1, 3, 1))
    }

    @Test func rejectsGarbage() {
        #expect(PlatformVersion("not a version") == nil)
        #expect(PlatformVersion("") == nil)
        // A bare commit hash has no dot and must not parse as a version.
        #expect(PlatformVersion("a9a62e2") == nil)
    }

    @Test func comparesByComponent() {
        #expect(PlatformVersion(1, 3, 0) < PlatformVersion(1, 3, 1))
        #expect(PlatformVersion(0, 5, 0) < PlatformVersion(1, 0, 0))
        #expect(PlatformVersion(1, 3, 1) < PlatformVersion(2, 0, 0))
    }

    @Test func exactMatchWinsRegardlessOfOrder() {
        // The exact pin must win even when it is not first on disk — davit #20:
        // a stale /usr/local install used to beat the platform we ship.
        let stale = binary("/usr/local", PlatformVersion(1, 3, 0))
        let exact = binary("/managed", PlatformInstaller.pinned)
        guard case .resolved(let picked) = ContainerBinary.choose(from: [stale, exact]) else {
            Issue.record("expected .resolved"); return
        }
        #expect(picked.installRoot == "/managed")
    }

    @Test func incompatibleMajorIsRejected() {
        // 0.x daemon can't answer a 1.x client's health check at all.
        let old = binary("/usr/local", PlatformVersion(0, 5, 0))
        guard case .incompatible(let list) = ContainerBinary.choose(from: [old]) else {
            Issue.record("expected .incompatible"); return
        }
        #expect(list.count == 1)
        #expect(list.first?.installRoot == "/usr/local")
    }

    @Test func compatibleMinorIsUsable() {
        // Same major, older patch: usable (exact pin absent).
        let older = binary("/usr/local", PlatformVersion(1, 2, 9))
        guard case .resolved(let picked) = ContainerBinary.choose(from: [older]) else {
            Issue.record("expected .resolved"); return
        }
        #expect(picked.installRoot == "/usr/local")
    }

    @Test func unreadableVersionCountsAsUsable() {
        // No `--version` output must not make an install unusable — that was the
        // pre-probe behavior and refusing to start would be a regression.
        let unknown = binary("/usr/local", nil)
        guard case .resolved(let picked) = ContainerBinary.choose(from: [unknown]) else {
            Issue.record("expected .resolved"); return
        }
        #expect(picked.installRoot == "/usr/local")
    }

    @Test func noInstallsIsNotFound() {
        guard case .notFound = ContainerBinary.choose(from: []) else {
            Issue.record("expected .notFound"); return
        }
    }
}
