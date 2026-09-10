import Foundation
import Testing
@testable import OrchardCore

/// Unit tests for the pure compose parsing layer — no daemon, no containers.
/// Behavior is pinned to davit's parser (which deliberately deviates from
/// compose-go in documented places; see the README notes carried in Compose.swift).
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
        // davit emits the long spellings (--publish/--env) plus the project
        // ownership label that marks containers this compose path created.
        #expect(svc.managementArgs.contains("--publish"))
        #expect(svc.managementArgs.contains("8080:80"))
        #expect(svc.managementArgs.contains("com.davit.compose.project=test"))
        #expect(svc.processArgs.contains("--env"))
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
        // 300 * 0.001 is not exactly 0.3 in binary floating point — compare with tolerance.
        let ms = try? #require(Compose.parseDuration("300ms"))
        #expect(abs((ms ?? 0) - 0.3) < 0.000_001)
        #expect(Compose.parseDuration("nonsense") == nil)
    }
}
