# OrchardCore Skeleton Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Orchard skeleton — an `OrchardCore` Swift package (library + CLI + tests), wired into the Xcode app target with a shared scheme and CI, so `xcodebuild build`, `swift run orchard-cli`, and `swift test` all pass.

**Architecture:** Three-entry structure per spec §2: `Packages/OrchardCore` (local Swift package: `OrchardCore` library + `orchard-cli` executable + `Tests/`), the Xcode app target links the library, tests live ONLY in the package (`swift test`). Xcode project gains a local-package reference, sandbox off, Swift 5 mode; template test targets are removed.

**Tech Stack:** Swift 5 language mode, SwiftUI (existing template), ArgumentParser, swift-log, apple/container 1.3.0 (exact), containerization 0.41.0 (exact), Yams, NIO.

**Spec:** `docs/superpowers/specs/2026-09-01-orchard-container-manager-design.md`

## Global Constraints

- **Branch discipline:** ALL work happens on `feature/orchardcore-skeleton` in worktree `.worktrees/orchardcore-skeleton/`. NEVER commit to `main`. Working directory for every command in this plan: `/Users/xlee7/project/Orchard/orchard/.worktrees/orchardcore-skeleton/`.
- **Swift 5 mode:** `Package.swift` targets MUST set `.swiftLanguageMode(.v5)`; Xcode targets MUST keep `SWIFT_VERSION = 5.0` and MUST NOT have `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` or `SWIFT_APPROACHABLE_CONCURRENCY = YES`.
- **Sandbox:** App target `ENABLE_APP_SANDBOX = NO`.
- **Dependency pins:** `apple/container` `exact: "1.3.0"`, `apple/containerization` `exact: "0.41.0"` — NEVER `from:` for these two.
- **Single test entry:** unit tests live in `Packages/OrchardCore/Tests/OrchardCoreTests/`; run via `swift test --package-path Packages/OrchardCore`. No test targets in the Xcode project.
- **Xcode 26.6** (build 17F113) is the toolchain; `objectVersion = 77` pbxproj format.
- Commit messages: `feat:`, `chore:`, `build:`, `docs:` prefixes. Small commits per task.

---

### Task 1: OrchardCore package skeleton

**Files:**
- Create: `Packages/OrchardCore/Package.swift`
- Create: `Packages/OrchardCore/Sources/OrchardCore/OrchardCore.swift`
- Test: `Packages/OrchardCore/Tests/OrchardCoreTests/OrchardCoreTests.swift`

**Interfaces:**
- Consumes: nothing (first task)
- Produces: `OrchardCore.versionString: String` (public static let, value `"0.1.0"`); package products `OrchardCore` (library) and `orchard-cli` (executable); test target `OrchardCoreTests`. Later tasks import `OrchardCore` and call `OrchardCore.versionString`.

- [ ] **Step 1: Write the failing test**

Create `Packages/OrchardCore/Tests/OrchardCoreTests/OrchardCoreTests.swift`:

```swift
import Testing
@testable import OrchardCore

struct OrchardCoreTests {
    @Test func versionStringIsPresent() {
        #expect(OrchardCore.versionString == "0.1.0")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/OrchardCore`
Expected: FAIL — package has no such module/product (or `swift test` errors "no tests found" / cannot build).

- [ ] **Step 3: Write minimal implementation**

Create `Packages/OrchardCore/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrchardCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OrchardCore", targets: ["OrchardCore"]),
        .executable(name: "orchard-cli", targets: ["orchard-cli"]),
    ],
    dependencies: [
        // Pinned to the exact release matching the installed container-apiserver.
        // Client and daemon ship in lockstep; do not use `from:` here.
        .package(url: "https://github.com/apple/container.git", exact: "1.3.0"),
        .package(url: "https://github.com/apple/containerization.git", exact: "0.41.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    ],
    targets: [
        .target(
            name: "OrchardCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "orchard-cli",
            dependencies: [
                "OrchardCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OrchardCoreTests",
            dependencies: ["OrchardCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

Create `Packages/OrchardCore/Sources/OrchardCore/OrchardCore.swift`:

```swift
/// Root namespace for the Orchard core library.
public enum OrchardCore {
    /// The library version, surfaced by the CLI and About UI.
    public static let versionString = "0.1.0"
}
```

Note: Task 2 will replace the CLI placeholder. Until then, the `orchard-cli` executable target needs a source entry point, and it MUST be a top-level-code file (a file named `main.swift`), because the placeholder cannot use `@main`. Create `Packages/OrchardCore/Sources/orchard-cli/main.swift` with:

```swift
print("orchard-cli placeholder")
```

Task 2 deletes this file and creates `OrchardCLI.swift` with `@main`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/OrchardCore`
Expected: PASS, 1 test. (First run fetches the 6 dependencies; may take several minutes.)

- [ ] **Step 5: Commit**

```bash
git add Packages/OrchardCore
git commit -m "build: add OrchardCore package skeleton (library + CLI target + test)"
```

---

### Task 2: orchard-cli entry point

**Files:**
- Create: `Packages/OrchardCore/Sources/orchard-cli/OrchardCLI.swift`

> **Why not `main.swift`?** Swift forbids `@main` in a file named `main.swift` (that file is the top-level-code entry point; `@main` in it is a compile error). Name the file `OrchardCLI.swift` so `@main struct OrchardCLI` is valid.

**Interfaces:**
- Consumes: `OrchardCore.versionString`
- Produces: executable `orchard-cli` with root command `orchard` and subcommand `version`. Later tasks add more subcommands under `OrchardCLI.CommandConfiguration.subcommands`.

- [ ] **Step 1: Write the failing test**

The CLI output is verified by running it (integration-style check), so the test here is a behavioral check via `swift run`:

Run: `swift run --package-path Packages/OrchardCore orchard-cli --help`
Expected: FAIL — command not recognized / placeholder behavior (empty or wrong output).

- [ ] **Step 2: Implement the CLI**

Delete the placeholder from Task 1: `git rm Packages/OrchardCore/Sources/orchard-cli/main.swift` (an `@main` type cannot coexist with a `main.swift` top-level-code file in the same target).

Create `Packages/OrchardCore/Sources/orchard-cli/OrchardCLI.swift`:

```swift
import ArgumentParser
import OrchardCore

@main
struct OrchardCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orchard",
        abstract: "Manage Apple's container platform",
        subcommands: [Version.self]
    )

    struct Version: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the orchard version"
        )

        func run() throws {
            print("orchard \(OrchardCore.versionString)")
        }
    }
}
```

- [ ] **Step 3: Verify it works**

Run: `swift run --package-path Packages/OrchardCore orchard-cli --help`
Expected: usage text listing the `version` subcommand.

Run: `swift run --package-path Packages/OrchardCore orchard-cli version`
Expected: `orchard 0.1.0`

- [ ] **Step 4: Commit**

```bash
git add Packages/OrchardCore/Sources/orchard-cli/OrchardCLI.swift
git commit -m "feat: add orchard-cli entry point (ArgumentParser, version subcommand)"
```

---

### Task 3: Wire OrchardCore into the Xcode project

**Files:**
- Modify: `orchard.xcodeproj/project.pbxproj`
- Create: `orchard.xcodeproj/xcshareddata/xcschemes/orchard.xcscheme`
- Delete (physical): `orchardTests/`, `orchardUITests/` directories

**Interfaces:**
- Consumes: package product `OrchardCore` from Task 1
- Produces: Xcode app target that links `OrchardCore`, has `ENABLE_APP_SANDBOX = NO`, Swift 5 mode, no `SWIFT_DEFAULT_ACTOR_ISOLATION`/`SWIFT_APPROACHABLE_CONCURRENCY`; no test targets; shared scheme `orchard` usable by `xcodebuild -scheme orchard`.

**Caution:** pbxproj is hand-edited here (no xcodeproj gem). Backup before editing, and after every edit run `plutil -lint orchard.xcodeproj/project.pbxproj` (pbxproj is an OpenStep plist; `plutil -lint` parses it) and `xcodebuild -list -project orchard.xcodeproj` to prove the project still parses.

- [ ] **Step 1: Backup**

```bash
cp orchard.xcodeproj/project.pbxproj /tmp/project.pbxproj.bak
```

- [ ] **Step 2: Add local package reference sections**

Insert these two sections right after the `/* Begin PBXFileSystemSynchronizedRootGroup section */` block's `/* End ... */` line (i.e. after line 48) in `orchard.xcodeproj/project.pbxproj`:

```
/* Begin XCLocalSwiftPackageReference section */
		AB0000000000000000000001 /* XCLocalSwiftPackageReference "OrchardCore" */ = {
			isa = XCLocalSwiftPackageReference;
			relativePath = ../Packages/OrchardCore;
		};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		AB0000000000000000000002 /* OrchardCore */ = {
			isa = XCSwiftPackageProductDependency;
			productName = OrchardCore;
		};
/* End XCSwiftPackageProductDependency section */
```

- [ ] **Step 3: Register the package on the project object**

In the `PBXProject` section (`A52EDE613046F99A00197DDD`), add `packageReferences` next to the existing `mainGroup = A52EDE603046F99A00197DDD;` line:

```
			packageReferences = (
				AB0000000000000000000001 /* XCLocalSwiftPackageReference "OrchardCore" */,
			);
```

- [ ] **Step 4: Reference the product from the app target**

In the `PBXNativeTarget` for `orchard` (`A52EDE683046F99A00197DDD`), replace:

```
			packageProductDependencies = (
			);
```

with:

```
			packageProductDependencies = (
				AB0000000000000000000002 /* OrchardCore */,
			);
```

- [ ] **Step 5: Add the package group to the main group**

In the `PBXGroup` `A52EDE603046F99A00197DDD` children list, add a file reference for the package folder. First add this entry to the `PBXFileReference` section (after line 29):

```
		AB0000000000000000000003 /* OrchardCore */ = {isa = PBXFileReference; lastKnownFileType = wrapper; name = OrchardCore; path = ../Packages/OrchardCore; sourceTree = "<group>"; };
```

Then add `AB0000000000000000000003 /* OrchardCore */,` to the children of `A52EDE603046F99A00197DDD` (before the `Products` entry).

- [ ] **Step 6: Verify the project still parses**

Run: `plutil -lint orchard.xcodeproj/project.pbxproj && xcodebuild -list -project orchard.xcodeproj`
Expected: lint OK; targets still list `orchard`, `orchardTests`, `orchardUITests`.

- [ ] **Step 7: App build settings — sandbox off, Swift 5 mode**

In the two `XCBuildConfiguration` blocks for the app target (`A52EDE8B3046F99B00197DDD /* Debug */` and `A52EDE8C3046F99B00197DDD /* Release */`):

- Change `ENABLE_APP_SANDBOX = YES;` → `ENABLE_APP_SANDBOX = NO;`
- Delete the two lines:
  - `SWIFT_APPROACHABLE_CONCURRENCY = YES;`
  - `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;`
- Keep `SWIFT_VERSION = 5.0;` as-is.

(Only the app target's two blocks — NOT the project-level `A52EDE88/89` blocks, NOT the test targets.)

- [ ] **Step 8: Remove template test targets from pbxproj**

Delete the following entries entirely (each is a complete `ID /* name */ = { ... };` object, plus its surrounding section if the section becomes empty):

1. `PBXNativeTarget`: `A52EDE753046F99B00197DDD /* orchardTests */`, `A52EDE7F3046F99B00197DDD /* orchardUITests */`
2. `PBXContainerItemProxy`: `A52EDE773046F99B00197DDD`, `A52EDE813046F99B00197DDD`
3. `PBXTargetDependency`: `A52EDE783046F99B00197DDD`, `A52EDE823046F99B00197DDD`
4. `PBXFileReference`: `A52EDE763046F99B00197DDD /* orchardTests.xctest */`, `A52EDE803046F99B00197DDD /* orchardUITests.xctest */`
5. `PBXFileSystemSynchronizedRootGroup`: `A52EDE793046F99B00197DDD /* orchardTests */`, `A52EDE833046F99B00197DDD /* orchardUITests */`
6. Build phases: `PBXSourcesBuildPhase` `A52EDE723046F99B00197DDD` + `A52EDE7C3046F99B00197DDD`; `PBXFrameworksBuildPhase` `A52EDE733046F99B00197DDD` + `A52EDE7D3046F99B00197DDD`; `PBXResourcesBuildPhase` `A52EDE743046F99B00197DDD` + `A52EDE7E3046F99B00197DDD`
7. `XCBuildConfiguration`: `A52EDE8E`, `A52EDE8F`, `A52EDE91`, `A52EDE92` (test Debug/Release blocks)
8. `XCConfigurationList`: `A52EDE8D3046F99B00197DDD`, `A52EDE903046F99B00197DDD`

Then edit references:
- Main group `A52EDE603046F99A00197DDD` children: remove `A52EDE793046F99B00197DDD /* orchardTests */,` and `A52EDE833046F99B00197DDD /* orchardUITests */,`
- Products group `A52EDE6A3046F99A00197DDD` children: remove `A52EDE763046F99B00197DDD /* orchardTests.xctest */,` and `A52EDE803046F99B00197DDD /* orchardUITests.xctest */,`
- `PBXProject` targets list: keep only `A52EDE683046F99A00197DDD /* orchard */`
- `PBXProject` TargetAttributes: remove the `A52EDE753046F99B00197DDD` and `A52EDE7F3046F99B00197DDD` entries (keep `A52EDE683046F99B00197DDD`)

Delete the empty sections (e.g. `PBXContainerItemProxy`, `PBXTargetDependency`) only if they contain no remaining entries — for this project they become fully empty, so delete the whole `/* Begin ... */` … `/* End ... */` blocks.

- [ ] **Step 9: Delete physical test directories**

```bash
rm -rf orchardTests orchardUITests
```

- [ ] **Step 10: Create the shared scheme**

Create `orchard.xcodeproj/xcshareddata/xcschemes/orchard.xcscheme`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2660"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "A52EDE683046F99A00197DDD"
               BuildableName = "orchard.app"
               BlueprintName = "orchard"
               ReferencedContainer = "container:orchard.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "A52EDE683046F99A00197DDD"
            BuildableName = "orchard.app"
            BlueprintName = "orchard"
            ReferencedContainer = "container:orchard.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "A52EDE683046F99A00197DDD"
            BuildableName = "orchard.app"
            BlueprintName = "orchard"
            ReferencedContainer = "container:orchard.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
```

- [ ] **Step 11: Verify the whole wiring**

Run: `xcodebuild -list -project orchard.xcodeproj`
Expected: targets list shows ONLY `orchard`; schemes list shows `orchard`.

Run: `xcodebuild build -project orchard.xcodeproj -scheme orchard -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED. (First build resolves the local package + its 6 dependencies through Xcode; allow several minutes.)

- [ ] **Step 12: Commit**

```bash
git add orchard.xcodeproj/project.pbxproj orchard.xcodeproj/xcshareddata
git rm -r orchardTests orchardUITests
git commit -m "build: wire OrchardCore package into Xcode project; remove template test targets; add shared scheme"
```

---

### Task 4: App target links and uses OrchardCore

**Files:**
- Modify: `orchard/orchardApp.swift`
- Modify: `orchard/ContentView.swift`

**Interfaces:**
- Consumes: `OrchardCore.versionString`
- Produces: an app that visibly shows `orchard 0.1.0` — proves the app target actually links the library (Task 3 wired the reference; this proves it resolves).

- [ ] **Step 1: Import and use OrchardCore in the app**

Replace the entire contents of `orchard/ContentView.swift` with:

```swift
import SwiftUI
import OrchardCore

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "shippingbox.fill")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Orchard \(OrchardCore.versionString)")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
```

Leave `orchard/orchardApp.swift` unchanged.

- [ ] **Step 2: Verify the build links the library**

Run: `xcodebuild build -project orchard.xcodeproj -scheme orchard -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED (proves `import OrchardCore` resolves and links).

- [ ] **Step 3: Commit**

```bash
git add orchard/ContentView.swift
git commit -m "feat: show Orchard version in app (links OrchardCore library)"
```

---

### Task 5: CI workflow and README build docs

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1–4 (the three verification commands must be green on a clean checkout)
- Produces: CI that fails the PR/push if any of the three commands fail.

- [ ] **Step 1: Create the CI workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main, dev]
  pull_request:

jobs:
  build:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - name: Unit tests (OrchardCore)
        run: swift test --package-path Packages/OrchardCore

      - name: Build app
        run: xcodebuild build -project orchard.xcodeproj -scheme orchard -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

      - name: Build CLI
        run: swift build --package-path Packages/OrchardCore
```

- [ ] **Step 2: Update README build/test commands**

In `README.md`, replace the `# Unit tests (no daemon required)` block:

```
# Unit tests (no daemon required)
xcodebuild test -scheme orchard -destination 'platform=macOS'
```

with:

```
# Unit tests (no daemon required)
swift test --package-path Packages/OrchardCore
```

- [ ] **Step 3: Verify YAML validity**

Run: `ruby -e 'require "yaml"; YAML.load_file(".github/workflows/ci.yml"); puts "yaml OK"'`
Expected: `yaml OK`

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml README.md
git commit -m "ci: add GitHub Actions workflow (tests, app build, CLI build); fix README test command"
```

---

### Task 6: Full verification and stage acceptance

**Files:** none (verification only)

**Interfaces:** — 

- [ ] **Step 1: Run every verification command from a clean state**

Run each and confirm all green:

1. `swift test --package-path Packages/OrchardCore` → PASS
2. `swift run --package-path Packages/OrchardCore orchard-cli --help` → usage with `version`
3. `swift run --package-path Packages/OrchardCore orchard-cli version` → `orchard 0.1.0`
4. `xcodebuild build -project orchard.xcodeproj -scheme orchard -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` → BUILD SUCCEEDED
5. `swift build --package-path Packages/OrchardCore` → build succeeded
6. `git status --short` → clean (only committed files)

- [ ] **Step 2: Confirm branch state**

Run: `git branch --show-current`
Expected: `feature/orchardcore-skeleton`. Nothing was committed to `main` or `dev` during this plan.

- [ ] **Step 3: Report stage acceptance**

Summarize results and report to the human: stage 0 complete, ready for human GUI smoke test (`open orchard.xcodeproj` or launch built app, confirm "Orchard 0.1.0" renders), then merge `feature/orchardcore-skeleton` → `dev` → `main` per spec §7.

---

## Self-Review

- **Spec coverage (§2, §5, §6, §8, §9-stage-0):** §2 structure (package + tests + app + CI + LICENSE/README) — Tasks 1–5. §5 constraints (Swift 5 both build systems, sandbox off, exact pins, single test entry) — Global Constraints + Tasks 1/3. §6 single test entry `swift test` — Tasks 1/5/6. §8 CI steps — Task 5. §9 stage-0 acceptance — Task 6. LICENSE already exists on the branch (from main).
- **Placeholder scan:** all steps contain concrete content; no TBD/TODO.
- **Type consistency:** `OrchardCore.versionString` defined Task 1, used Tasks 2/4. Package products named identically in Package.swift (Task 1) and pbxproj product dependency (Task 3). pbxproj IDs `AB0000000000000000000001..3` used consistently. BlueprintIdentifier in scheme matches app target `A52EDE683046F99A00197DDD` (verified against current pbxproj).
