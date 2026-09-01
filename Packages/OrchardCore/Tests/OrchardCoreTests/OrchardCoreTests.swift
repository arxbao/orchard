import Testing
@testable import OrchardCore

/// Smoke tests for the OrchardCore package skeleton.
///
/// These verify the package builds as a library and that the public root
/// namespace exposes the version consumers (app + CLI) rely on. Later
/// feature tasks add domain-specific suites here (compose parsing, flag
/// routing, stats math, ...) — all runnable without a container daemon.
struct OrchardCoreTests {
    @Test func versionStringIsPresent() {
        // The version string is the single source of truth surfaced by both
        // the GUI (About/version label) and the CLI (`orchard version`).
        #expect(OrchardCore.versionString == "0.1.0")
    }
}
