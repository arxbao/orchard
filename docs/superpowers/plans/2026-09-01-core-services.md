# Core Services Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the davit service layer into OrchardCore — `Environment`, `Errors`, `Models`, `ContainerService`, `MachineService`, `BuildService`, `RegistryService` — as a public-API library, extracting pure logic (stats math, flag routing, stop-reason parsing) into unit-tested functions.

**Architecture:** davit's `Backend.swift` (1758 lines) and sibling service files are split into per-domain files under `Packages/OrchardCore/Sources/OrchardCore/`. All symbols become `public` (davit used module-internal visibility; the GUI and CLI are separate modules now — spec §9 stage-1 note). Pure functions are extracted for `swift test` coverage with no daemon.

**Tech Stack:** Swift 5 mode, ContainerAPIClient (XPC), ContainerResource, ContainerPersistence, ContainerPlugin, ContainerizationExtras/OCI/OS, Logging, TerminalProgress, SystemPackage.

**Spec:** `docs/superpowers/specs/2026-09-01-orchard-container-manager-design.md` (§2/§3/§5/§6/§9-stage-1)

**Baseline source:** `/Users/xlee7/project/davit/Sources/ContainerStack/` (MIT, read-only reference — never modify).

## Global Constraints

- **Branch discipline:** ALL work on `feature/core-services` in worktree `.worktrees/core-services/`. NEVER commit to `main`/`dev`. Working directory for every command: `/Users/xlee7/project/Orchard/orchard/.worktrees/core-services/`.
- **Swift 5:** new target files keep `.swiftLanguageMode(.v5)` (already set package-wide); no actor-isolation defaults.
- **Visibility:** every type/member used by GUI or CLI becomes `public`; keep `internal` only for file-private helpers. Add doc comments to all public API (spec §1 comment policy).
- **Single test entry:** `swift test --package-path Packages/OrchardCore`. New tests live in `Packages/OrchardCore/Tests/OrchardCoreTests/`.
- **Comment policy:** every ported symbol keeps its davit comments (why-not-what); note workarounds for upstream bugs exactly as davit did.
- **Codegraph:** run `codegraph sync` after each task.
- Commit messages: `feat:`, `refactor:`, `test:` prefixes. One commit per task.
- The six package dependencies stay declared (container/containerization become *used* by this branch — the "not used by any target" warnings for them disappear; yams/swift-nio warnings remain until compose).

---

### Task 1: Core foundation — Environment, Errors, Models

**Files:**
- Create: `Packages/OrchardCore/Sources/OrchardCore/Environment.swift`
- Create: `Packages/OrchardCore/Sources/OrchardCore/Errors.swift`
- Create: `Packages/OrchardCore/Sources/OrchardCore/Models.swift`

**Interfaces:**
- Consumes: nothing new (package deps already declared)
- Produces (public): `Environment` namespace with `ContainerBinary.resolve()/bootstrapEnvironment()`, `LoggingConfig.parseLevel(_:)`, `ResolvedBinary`; `CLIError` (+`wrap`); all model types: `ContainerRecord`, `ContainerState`, `ContainerStatus`, `ContainerNetworkStatus`, `ContainerConfigurationInfo`, `ImageReferenceInfo`, `InitProcessInfo`, `MountRecord`, `PlatformRecord`, `PublishedPort`, `ResourceLimits`, `ImageRecord`, `NetworkRecord`, `VolumeRecord`, `StatsRecord`, `StatsSample`, `DiskUsage`, `SystemState`, plus `MachineRecord` (from Machine.swift) and `RegistryLoginRecord` (from Registry.swift). Later tasks build on these types.

- [ ] **Step 1: Copy Environment/Errors from davit Backend.swift**

Copy from `/Users/xlee7/project/davit/Sources/ContainerStack/Backend.swift`:
- `ContainerBinary` enum + `ResolvedBinary` struct (lines 16–123) → `Environment.swift`
- `LoggingConfig` enum (lines 90–109) → `Environment.swift`
- `CLIError` struct (lines 125–145) → `Errors.swift`

Keep the `import` lines exactly as davit has them (`Foundation`, `Logging`, `SystemPackage` as needed). Add `public` to every type, member, and property. Keep all comments verbatim.

- [ ] **Step 2: Copy Models.swift**

Copy `/Users/xlee7/project/davit/Sources/ContainerStack/Models.swift` (456 lines) verbatim into `Models.swift`, then add `public` to every `struct`/`enum` declaration, every property, and every member of `extension`s. Keep all `import`s (`ContainerResource`, `ContainerPersistence`, `Foundation` — whatever davit used). Also copy `MachineRecord` (Machine.swift lines 11–31) and `RegistryLoginRecord` (Registry.swift lines 7–15) into Models.swift with `public`.

- [ ] **Step 3: Build and run existing tests**

Run: `swift test --package-path Packages/OrchardCore`
Expected: existing 1 test passes; package compiles.

- [ ] **Step 4: Fix visibility fallout**

The existing `OrchardCoreTests` uses `OrchardCore.versionString` only, so no test changes. If compilation reports missing `public` on any member used across files, add it. Ensure no `internal` type leaks into another file's public signature.

- [ ] **Step 5: Commit + codegraph sync**

```bash
git add Packages/OrchardCore
git commit -m "feat: add OrchardCore foundation (Environment, Errors, Models) ported from davit"
codegraph sync
```

---

### Task 2: ContainerService + system bootstrap + stop reasons

**Files:**
- Create: `Packages/OrchardCore/Sources/OrchardCore/ContainerService.swift`
- Create: `Packages/OrchardCore/Sources/OrchardCore/SystemController.swift`
- Create: `Packages/OrchardCore/Sources/OrchardCore/StopReason.swift`

**Interfaces:**
- Consumes: `Environment`, `Errors`, `Models` (Task 1)
- Produces (public): `ExpectedStops`, `Backend` (shared `systemConfig()`/`prettyJSON`), `ContainerService` with all static methods from davit Backend.swift lines 191–726 + extensions (recreate prefill 1512–1555, stop reasons 1615–1680), `SystemController.start/stop/ensureKernel` (729–808), `SystemConfigStore` (1136–…), `StopReason` enum + parsers, `VolumeBrowser` (1728–1758). `ContainerService.stopReason(fromStdioLines:kernelLines:)` and `stopReason(fromKernelLines:)` stay pure (no I/O) so Task 3 can unit-test them.

- [ ] **Step 1: Port ContainerService core**

Copy from davit `Backend.swift` lines 191–726 (`enum ContainerService` with `listContainers`, `listImages`, `imageExists`, `listNetworks`, `listVolumes`, `stats`, `containerDiskUsage`, `diskUsage`, `start/stop/kill/restart/delete`, `exportContainer`, `pruneContainers`, `stopAll`, `runContainer`, `pullImage`, `deleteImage`, `pruneImages`, `tagImage`, `createVolume`, `deleteVolume`, `pruneVolumes`, `usedVolumeNames`, `createNetwork`, `deleteNetwork`, `pruneNetworks`, `systemState`, `hasDefaultKernel`, `configureDefaultKernel`, `systemStart`, `friendlyStartError`, `systemStop`, `properties`, `imageLayers`, `inspectRaw`) into `ContainerService.swift`. Also copy `ExpectedStops` (173–189) and `Backend` (148–166). Make everything `public`. Keep davit's `import`s (ContainerAPIClient, ContainerResource, ContainerizationOCI, Logging, etc.).

- [ ] **Step 2: Port SystemController and SystemConfigStore**

Copy `SystemController` (729–808) into `SystemController.swift` and `SystemConfigStore` (1136–~1400, includes `runTool`) into `ContainerService.swift` (or a separate `SystemConfigStore.swift` — same directory, same visibility rules). `public` everywhere.

- [ ] **Step 3: Port StopReason + parsers**

Copy `StopReason` (1601–1613) and the two pure parser extensions `stopReason(fromStdioLines:kernelLines:)` / `stopReason(fromKernelLines:)` + helpers `auxVectorType(in:)`, `killedProcessName(in:)` (1615–1680) into `StopReason.swift`. Keep them as `extension ContainerService` (matching davit) or move to a standalone `StopReasonParser` enum — **standalone enum preferred** (testable without the rest of ContainerService):

```swift
public enum StopReasonParser {
    public static func stopReason(fromStdioLines stdio: [String], kernelLines kernel: [String]) -> StopReason?
    public static func stopReason(fromKernelLines lines: [String]) -> StopReason?
    static func auxVectorType(in line: String) -> String?
    static func killedProcessName(in line: String) -> String?
}
```

(Adjust the async `ContainerService.stopReason(_ id:)` caller in Task 3's integration to call `StopReasonParser`.) Copy the pure logic from davit lines 1631–1679 verbatim, adapted to the enum.

- [ ] **Step 4: Build**

Run: `swift test --package-path Packages/OrchardCore`
Expected: compiles, existing tests pass. (No new tests yet — pure parsers get tested in Task 3.)

- [ ] **Step 5: Commit + codegraph sync**

```bash
git add Packages/OrchardCore
git commit -m "feat: port ContainerService, SystemController, StopReason from davit (public API)"
codegraph sync
```

---

### Task 3: Pure-logic extraction + TDD unit tests

**Files:**
- Create: `Packages/OrchardCore/Sources/OrchardCore/StatsCalculator.swift`
- Create: `Packages/OrchardCore/Sources/OrchardCore/FlagRouter.swift`
- Test: `Packages/OrchardCore/Tests/OrchardCoreTests/StopReasonTests.swift`
- Test: `Packages/OrchardCore/Tests/OrchardCoreTests/StatsCalculatorTests.swift`
- Test: `Packages/OrchardCore/Tests/OrchardCoreTests/FlagRouterTests.swift`

**Interfaces:**
- Consumes: `StopReason` (Task 2); davit `AppState.refreshStats()` differential math (AppState.swift lines 292–349); davit `RunCLI.parseArgs` flag routing (Main.swift lines 772–903)
- Produces (public): `StatsCalculator` (pure: `cpuPercent(now:prev:)`, `rate(now:prev:)`, `sample(...)` — extracted from AppState's inline math); `FlagRouter` (pure: `parse(args:) -> Invocation` with `Invocation{image, command, process, management, resource, name, cidfile, detach, autoRemove, pullPolicy, verbose, quiet}`). GUI and CLI both consume these.

- [ ] **Step 1: Write failing StopReason tests**

Create `StopReasonTests.swift`:

```swift
import Testing
@testable import OrchardCore

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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path Packages/OrchardCore --filter StopReasonTests`
Expected: FAIL — `StopReasonParser` not found (Task 2's enum has the logic; if Step 3 of Task 2 already landed, this passes — adjust: write tests BEFORE the enum exists is impossible since Task 2 created it. If `StopReasonParser` already exists, skip to Step 4.)

> **Plan note:** Task 2 Step 3 creates `StopReasonParser`; if it landed, these tests pass immediately. If Task 2 kept davit's `extension ContainerService` shape instead, first refactor it into `StopReasonParser` (small, mechanical) so the tests apply.

- [ ] **Step 3: (only if parser is not standalone) Refactor to StopReasonParser**

Move the pure functions out of `extension ContainerService` into `enum StopReasonParser` (same bodies, `public`). Update any caller.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path Packages/OrchardCore --filter StopReasonTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Write failing StatsCalculator tests**

Create `StatsCalculator.swift` in Sources — extract the differential math from davit `AppState.refreshStats()` (AppState.swift:309–341): CPU% from `cpuUsec` delta over `dt`, and read/write rates from byte deltas. Public API:

```swift
public enum StatsCalculator {
    public struct Delta { public let cpuPercent: Double; public let diskReadRate: Double; public let diskWriteRate: Double }
    public static func delta(cpuUsec: Int64, blockRead: Int64, blockWrite: Int64, dt: TimeInterval) -> Delta?
}
```

Create `StatsCalculatorTests.swift`:

```swift
import Testing
@testable import OrchardCore

struct StatsCalculatorTests {
    @Test func cpuPercentFromDelta() {
        // 1 second apart, 50% of one core: 0.5 * 1_000_000 usec
        let d = StatsCalculator.delta(cpuUsec: 1_500_000, blockRead: 0, blockWrite: 0, dt: 1.0)
        #expect(d?.cpuPercent == 50.0)
    }

    @Test func zeroDtIsRejected() {
        #expect(StatsCalculator.delta(cpuUsec: 100, blockRead: 0, blockWrite: 0, dt: 0.05) == nil)
    }

    @Test func byteRates() {
        let d = StatsCalculator.delta(cpuUsec: 0, blockRead: 1_048_576, blockWrite: 2_097_152, dt: 1.0)
        #expect(d?.diskReadRate == 1_048_576)
        #expect(d?.diskWriteRate == 2_097_152)
    }
}
```

Note: davit rejects `dt <= 0.1`; port that threshold (0.1, not 0.05 — adjust the zeroDt test to `dt: 0.05` expecting nil because `dt < 0.1`).

- [ ] **Step 6: Run to verify failure**

Run: `swift test --package-path Packages/OrchardCore --filter StatsCalculatorTests`
Expected: FAIL — `StatsCalculator` not found.

- [ ] **Step 7: Implement StatsCalculator**

Implement per the davit math (AppState.swift:309–324): `guard dt > 0.1 else { return nil }`; `cpuPercent = Double(max(0, cpuUsec - prev)) / (dt * 1_000_000) * 100`.

- [ ] **Step 8: Run to verify pass**

Run: `swift test --package-path Packages/OrchardCore --filter StatsCalculatorTests`
Expected: PASS (3 tests).

- [ ] **Step 9: Write failing FlagRouter tests**

Create `FlagRouter.swift` in Sources — port davit `RunCLI.parseArgs` (Main.swift:772–903) minus the process-exiting shell: pure `parse(args:) throws -> Invocation`, `ParseError` thrown on bad flags. Keep the `unsupported` set, clustered-short-flag expansion, `--flag=value` handling.

Create `FlagRouterTests.swift`:

```swift
import Testing
@testable import OrchardCore

struct FlagRouterTests {
    @Test func routesFlagsToBuckets() throws {
        let inv = try FlagRouter.parse(["-d", "-p", "8080:80", "-e", "FOO=1", "--rm", "nginx", "arg1"])
        #expect(inv.detach == true)
        #expect(inv.autoRemove == true)
        #expect(inv.management == ["-p", "8080:80"])
        #expect(inv.process == ["-e", "FOO=1"])
        #expect(inv.image == "nginx")
        #expect(inv.command == ["arg1"])
    }

    @Test func unsupportedFlagFails() {
        #expect(throws: FlagRouter.ParseError.self) {
            _ = try FlagRouter.parse(["--privileged", "nginx"])
        }
    }

    @Test func clusteredShortFlagsExpand() throws {
        let inv = try FlagRouter.parse(["-it", "nginx"])
        #expect(inv.command == [])
        // -i is rejected with a tailored message; -t is a process flag
    }
}
```

(Verify against davit's actual `parseArgs` semantics: `-i` throws ParseError with "interactive runs aren't supported". Adjust the third test's expectation to match: `-it` should throw the interactive error.)

- [ ] **Step 10: Run to verify failure**

Run: `swift test --package-path Packages/OrchardCore --filter FlagRouterTests`
Expected: FAIL — `FlagRouter` not found.

- [ ] **Step 11: Implement FlagRouter**

Port davit `RunCLI.parseArgs` verbatim into `enum FlagRouter`, renaming `parseArgs` → `parse`, making types public. `ParseError: Error, Equatable` public with `message: String?` and `isHelp: Bool`.

- [ ] **Step 12: Run to verify pass**

Run: `swift test --package-path Packages/OrchardCore --filter FlagRouterTests`
Expected: PASS (3 tests).

- [ ] **Step 13: Full test run + commit + codegraph sync**

Run: `swift test --package-path Packages/OrchardCore`
Expected: 10 tests pass (1 smoke + 3 stop + 3 stats + 3 flag).

```bash
git add Packages/OrchardCore
git commit -m "test: extract StatsCalculator, FlagRouter; unit-test stop-reason parsing (10 tests)"
codegraph sync
```

---

### Task 4: Machine, Build, Registry, FileSystem services

**Files:**
- Create: `Packages/OrchardCore/Sources/OrchardCore/MachineService.swift`
- Create: `Packages/OrchardCore/Sources/OrchardCore/BuildService.swift`
- Create: `Packages/OrchardCore/Sources/OrchardCore/RegistryService.swift`
- Create: `Packages/OrchardCore/Sources/OrchardCore/DockerCredHelpers.swift`
- Create: `Packages/OrchardCore/Sources/OrchardCore/FileSystemService.swift`

**Interfaces:**
- Consumes: `ContainerService`, `Environment`, `Models` (Tasks 1–2)
- Produces (public): `MachineService` (list/create/boot/stop/delete/inspectJSON/setConfig/execShell/setDefault); `BuildService` (build); `RegistryService` (listLogins/login/saveTrustingPlatform/logout) + `DockerCredHelpers`; `ContainerService` extensions from FileSystem.swift (exec-with-output, directory listing, download/upload/delete).

- [ ] **Step 1: Port MachineService**

Copy `Machine.swift` (203 lines) → `MachineService.swift`, `public` everywhere, keep imports.

- [ ] **Step 2: Port BuildService**

Copy `Build.swift` (164 lines) → `BuildService.swift`, `public`.

- [ ] **Step 3: Port Registry + credential helpers**

Copy `Registry.swift` (124 lines) → `RegistryService.swift` and `DockerCredHelpers.swift` (120 lines) → `DockerCredHelpers.swift`, `public`.

- [ ] **Step 4: Port FileSystem service extensions**

Copy `FileSystem.swift` (207 lines) → `FileSystemService.swift` as `extension ContainerService` (exec with captured output, `ExecResult`/`ExecTimeout`, directory listing, download/upload/delete), `public`.

- [ ] **Step 5: Build**

Run: `swift test --package-path Packages/OrchardCore`
Expected: compiles; all 10 tests pass.

- [ ] **Step 6: Commit + codegraph sync**

```bash
git add Packages/OrchardCore
git commit -m "feat: port Machine/Build/Registry/DockerCredHelpers/FileSystem services from davit"
codegraph sync
```

---

### Task 5: Full verification and stage acceptance

**Files:** none (verification only)

**Interfaces:** —

- [ ] **Step 1: Full test run**

Run: `swift test --package-path Packages/OrchardCore`
Expected: all tests pass (≥10).

- [ ] **Step 2: App + CLI builds still green**

Run:
1. `xcodebuild build -project orchard.xcodeproj -scheme orchard -configuration Debug -derivedDataPath .tmp/DerivedData -skipPackageUpdates` → BUILD SUCCEEDED
2. `swift run --package-path Packages/OrchardCore orchard-cli version` → `orchard 0.1.0`

(The app does not call the new services yet — Task 3/GUI branches wire them. Build success proves the library still links.)

- [ ] **Step 3: Branch state + git clean**

Run: `git branch --show-current` → `feature/core-services`; `git status --short` → clean.

- [ ] **Step 4: Verify warnings reduced**

Run: `swift build --package-path Packages/OrchardCore 2>&1 | grep "not used by any target"` — `container`/`containerization`/`swift-log` must NOT appear (now used); `yams`/`swift-nio` may still appear (compose stage).

- [ ] **Step 5: Report**

Report to the human: stage 1 done — service layer ported with public API, 10+ unit tests green, pure logic extracted. Ready for human review (no GUI smoke needed this stage — no UI change), then merge `feature/core-services` → `dev` → `main`.

---

## Self-Review

- **Spec coverage:** §3 file mapping (Backend.swift split into Environment/Errors/ContainerService/SystemController/StopReason; Models; Machine/Build/Registry) — Tasks 1/2/4. §6 test list (compose parser later; flag routing/stats/stop-reason now) — Task 3. §9 stage-1 acceptance (tests for flag/stats/stop-reason) — Task 3 + Task 5. §5 single test entry + Swift 5 — Global Constraints + Tasks.
- **Placeholder scan:** no TBD/TODO; test code and commands concrete.
- **Type consistency:** `StopReasonParser.stopReason(fromStdioLines:kernelLines:)` used in Task 3 tests matches Task 2 Step 3; `StatsCalculator.delta(cpuUsec:blockRead:blockWrite:dt:)` consistent between tests and implementation; `FlagRouter.parse(_:)` / `Invocation` field names (`detach`, `autoRemove`, `management`, `process`, `image`, `command`) match davit's `RunCLI.Invocation`.
- **Known risk (documented):** Task 2 Step 3 ordering vs Task 3 Step 1 — resolved by the plan note (if `StopReasonParser` exists, tests pass immediately; refactor first if it doesn't).
