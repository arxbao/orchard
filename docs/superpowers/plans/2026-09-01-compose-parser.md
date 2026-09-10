# Compose Parser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port davit's compose *parsing* layer (davit `Compose.swift` lines 1–1010) into OrchardCore as pure, unit-tested code — file autodiscovery, `.env` interpolation, YAML → `Plan` with topologically ordered `ServicePlan`s, and profile/dependency service selection. The *execution* layer (up/down/logs/…) stays in davit and is ported in the GUI/compose stage.

**Architecture:** Two files under `Packages/OrchardCore/Sources/OrchardCore/`: `Compose.swift` (the `Compose` namespace: types + parse + discovery + env) and `ComposePlan.swift` (`Plan` extension: `selecting` / profile gating / dependency closure). All public. Yams becomes a *used* dependency (its "not used by any target" warning disappears); swift-nio stays unused until the log-streaming stage.

**Tech Stack:** Swift 5 mode, Yams (YAML), Foundation. No XPC, no daemon.

**Spec:** `docs/superpowers/specs/2026-09-01-orchard-container-manager-design.md` (§6 test list, §9 stage-2)

**Baseline source:** `/Users/xlee7/project/davit/Sources/ContainerStack/Compose.swift` (MIT, read-only reference).

## Global Constraints

- **Branch discipline:** work on `feature/core-compose-parser` in `.worktrees/core-compose-parser/`. NEVER commit to `main`/`dev`. Working dir for every command: `/Users/xlee7/project/Orchard/orchard/.worktrees/core-compose-parser/`.
- **Port fidelity:** copy davit's parsing logic and comments verbatim; only change visibility (`public`) and file placement. Do NOT "improve" parse semantics in this stage — parity is the point; the unit tests pin the behavior.
- **Swift 5 mode / single test entry:** unchanged from stage 1 (`swift test --package-path Packages/OrchardCore`).
- **Comment policy (spec §1):** keep davit's why-not-what comments; add doc comments on public API.
- **Codegraph:** `codegraph sync` after each task.
- Commit messages: `feat:` / `test:`.

---

### Task 1: Port the Compose parsing layer

**Files:**
- Create: `Packages/OrchardCore/Sources/OrchardCore/Compose.swift`
- Modify: `Packages/OrchardCore/Package.swift` (add Yams product to OrchardCore target)

**Interfaces:**
- Consumes: nothing from earlier stages except `CLIError` (Errors.swift)
- Produces (public): `Compose` enum with nested `ServicePlan`, `BuildSpec`, `Plan`, `Healthcheck`, `DependsCondition`, `Error`; `Compose.parse(text:projectName:baseDir:environment:) throws -> Plan`; `Compose.discoverFile(startingAt:)`; `Compose.effectiveEnvironment(composeDir:envFile:) throws -> ([String: String], [String])`; `Compose.parseDuration(_:)`; `Compose.shellSplit(_:)`; `Compose.shellQuote(_:)`; `Compose.projectLabel`.

- [ ] **Step 1: Add Yams to the target**

In `Package.swift`, add to the `OrchardCore` target's `dependencies`:

```swift
                .product(name: "Yams", package: "Yams"),
```

- [ ] **Step 2: Extract the parsing layer from davit**

Copy `/Users/xlee7/project/davit/Sources/ContainerStack/Compose.swift` lines **1–959** (from `import ContainerAPIClient` through the end of `shellQuote`) into the new `Compose.swift`, with these adjustments:
- Keep the file header comment (the "Docker Compose import" doc comment) verbatim.
- Replace `import ContainerAPIClient` / `import TerminalProgress` with only what the parsing layer needs: `import Foundation` and `import Yams`. (The parsing layer needs neither XPC nor progress UI — if the compiler disagrees, add back the minimal import.)
- Add `public` to: `enum Compose`, `static let projectLabel`, and every nested type (`ServicePlan`, `BuildSpec`, `Plan`, `Healthcheck`, `DependsCondition`, `Error`) plus all their `public`-reachable members, and the free functions in Step 3.
- `ServicePlan.cliPreview` calls `Compose.shellQuote` — keep both.

- [ ] **Step 3: Ensure the helper functions are public**

`parseDuration`, `shellSplit`, `shellQuote`, `discoverFile`, `effectiveEnvironment`, `parse` must all be `public static`. Keep their bodies and comments byte-identical to davit.

- [ ] **Step 4: Build**

Run: `swift build --package-path Packages/OrchardCore`
Expected: compiles. Fix only visibility/import issues — no logic edits.

- [ ] **Step 5: Confirm Yams warning is gone**

Run: `swift build --package-path Packages/OrchardCore 2>&1 | grep "not used by any target"`
Expected: only `swift-nio` remains.

- [ ] **Step 6: Commit + codegraph sync**

```bash
git add Packages/OrchardCore
git commit -m "feat: port compose parsing layer (types, parse, discovery, .env) from davit"
codegraph sync
```

---

### Task 2: Port Plan selection (profiles + dependency closure)

**Files:**
- Create: `Packages/OrchardCore/Sources/OrchardCore/ComposePlan.swift`

**Interfaces:**
- Consumes: `Compose.Plan`, `Compose.ServicePlan`, `Compose.Error` (Task 1)
- Produces (public): `Compose.Plan.selecting(services:activeProfiles:includeDependencies:) throws -> Compose.Plan` — davit's selection semantics: named services + transitive `depends_on` closure in topo order (when `includeDependencies`), profile gating (`*` activates all; explicitly named services auto-activate their own profiles), and pruning of volumes/networks to those the selected services reference. Also the `topoSort` helper it uses.

- [ ] **Step 1: Extract the selection extension**

Copy davit `Compose.swift` lines **960–1010** (`// MARK: - Selection` through the end of `extension Compose.Plan`) into `ComposePlan.swift`. Keep `import Foundation`. Make `selecting` and any helper `public`; add `public` to the extension's members.

- [ ] **Step 2: Build**

Run: `swift build --package-path Packages/OrchardCore`
Expected: compiles.

- [ ] **Step 3: Commit + codegraph sync**

```bash
git add Packages/OrchardCore
git commit -m "feat: port compose plan selection (profiles, dependency closure) from davit"
codegraph sync
```

---

### Task 3: Compose parser unit tests (TDD)

**Files:**
- Test: `Packages/OrchardCore/Tests/OrchardCoreTests/ComposeParserTests.swift`

**Interfaces:**
- Consumes: `Compose.parse`, `Compose.Plan.selecting`, `Compose.effectiveEnvironment`

- [ ] **Step 1: Write the tests**

Create `ComposeParserTests.swift`:

```swift
import Foundation
import Testing
@testable import OrchardCore

/// Unit tests for the pure compose parsing layer — no daemon, no containers.
struct ComposeParserTests {
    private func parse(_ yaml: String, project: String = "test") throws -> Compose.Plan {
        try Compose.parse(text: yaml, projectName: project, baseDir: "/tmp", environment: [:])
    }

    @Test func parsesServicesInDependencyOrder() throws {
        let plan = try parse("""
        services:
          web:
            image: nginx
            depends_on: [db]
          db:
            image: postgres
        """)
        #expect(plan.project == "test")
        #expect(plan.services.map(\.service) == ["db", "web"])  // topo: db before web
    }

    @Test func rejectsDependencyCycle() {
        #expect(throws: Compose.Error.self) {
            _ = try parse("""
            services:
              a:
                image: x
                depends_on: [b]
              b:
                image: x
                depends_on: [a]
            """)
        }
    }

    @Test func portsAndEnvironmentBecomeRunArgs() throws {
        let plan = try parse("""
        services:
          web:
            image: nginx
            ports: ["8080:80"]
            environment:
              FOO: bar
        """)
        let svc = try #require(plan.services.first)
        #expect(svc.managementArgs.contains("-p"))
        #expect(svc.managementArgs.contains("8080:80"))
        #expect(svc.processArgs.contains("-e"))
        #expect(svc.processArgs.contains("FOO=bar"))
    }

    @Test func profilesGateServices() throws {
        let plan = try parse("""
        services:
          always:
            image: x
          debug:
            image: y
            profiles: [dev]
        """)
        let active = try plan.selecting(services: [], activeProfiles: ["dev"], includeDependencies: false)
        #expect(active.services.map(\.service).sorted() == ["always", "debug"])
        let inactive = try plan.selecting(services: [], activeProfiles: [], includeDependencies: false)
        #expect(inactive.services.map(\.service) == ["always"])
    }

    @Test func selectionPullsInDependencyClosure() throws {
        let plan = try parse("""
        services:
          web:
            image: nginx
            depends_on: [db]
          db:
            image: postgres
        """)
        let selected = try plan.selecting(services: ["web"], activeProfiles: [], includeDependencies: true)
        #expect(selected.services.map(\.service) == ["db", "web"])
    }

    @Test func envFileInterpolation() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "TAG=1.2.3\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let (env, _) = try Compose.effectiveEnvironment(composeDir: dir.path, envFile: nil)
        #expect(env["TAG"] == "1.2.3")

        let plan = try Compose.parse(
            text: "services:\n  web:\n    image: nginx:${TAG}\n",
            projectName: "test", baseDir: dir.path, environment: env)
        #expect(plan.services.first?.image == "nginx:1.2.3")
    }

    @Test func unknownKeysWarnNotFail() throws {
        let plan = try parse("""
        services:
          web:
            image: nginx
            totally_unknown_key: 1
        """)
        #expect(plan.services.count == 1)
        #expect(!plan.warnings.isEmpty)
    }

    @Test func parseDurationSupportsGoSpellings() {
        #expect(Compose.parseDuration("5s") == 5)
        #expect(Compose.parseDuration("1m30s") == 90)
        #expect(Compose.parseDuration("300ms") == 0.3)
        #expect(Compose.parseDuration("nonsense") == nil)
    }
}
```

- [ ] **Step 2: Run and fix against real davit semantics**

Run: `swift test --package-path Packages/OrchardCore --filter ComposeParserTests`

The tests encode davit's documented behavior; where davit's actual output differs (e.g. a different warning text, a different arg spelling), **adapt the assertion to the real behavior** and keep a comment noting the exact expectation. Do not change the ported code to satisfy a wrong test — the port is the source of truth this stage. If a test reveals a genuine porting mistake (e.g. missing dependency closure), fix the port.

Expected: all tests pass (8 tests).

- [ ] **Step 3: Full test run**

Run: `swift test --package-path Packages/OrchardCore`
Expected: 19 tests pass (11 from stage 1 + 8 new).

- [ ] **Step 4: Commit + codegraph sync**

```bash
git add Packages/OrchardCore
git commit -m "test: add compose parser unit tests (parse, topo order, cycles, profiles, .env)"
codegraph sync
```

---

### Task 4: Full verification

**Files:** none

- [ ] **Step 1: All verifications**

1. `swift test --package-path Packages/OrchardCore` → all pass
2. `xcodebuild build -project orchard.xcodeproj -scheme orchard -configuration Debug -derivedDataPath .tmp/DerivedData -skipPackageUpdates` → BUILD SUCCEEDED
3. `swift run --package-path Packages/OrchardCore orchard-cli version` → `orchard 0.1.0`
4. `git status --short` → clean; `git branch --show-current` → `feature/core-compose-parser`
5. `swift build --package-path Packages/OrchardCore 2>&1 | grep "not used by any target"` → only `swift-nio`

- [ ] **Step 2: Report**

Report stage 2 complete: parse layer ported with 8 unit tests; then merge `feature/core-compose-parser` → **dev only** (main keeps its milestone policy — spec §7: main takes only major features/hotfixes).

---

## Self-Review

- **Spec coverage:** §6 (compose parse tests: subset, topo sort, cycle rejection, profiles, `.env`) — Task 3. §9 stage-2 (ComposeParser/ComposePlan pure parsing + tests green) — Tasks 1–3. §7 (merge to dev only) — Task 4 Step 2.
- **Placeholder scan:** no TBD/TODO; test code and commands concrete.
- **Type consistency:** `Compose.parse(text:projectName:baseDir:environment:)`, `Plan.selecting(services:activeProfiles:includeDependencies:)`, `effectiveEnvironment(composeDir:envFile:)`, `parseDuration(_:)` all match davit's signatures (verified against Main.swift call sites and Compose.swift:154/246/367/909/962).
- **Known risk (documented):** Task 3 Step 2 explicitly allows adapting *assertions* (not ported logic) to real behavior — davit's parse has several documented deviations from compose-go, so the tests pin davit's behavior, not docker's.
