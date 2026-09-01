import Testing
@testable import OrchardCore

/// Unit tests for the docker-flag router extracted from davit's
/// `RunCLI.parseArgs` (Main.swift:772–903) — pure argv → Invocation mapping
/// shared by the CLI (`orchard run`) and later the GUI Run sheet.
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
        // --privileged has no equivalent on apple/container — must fail loudly,
        // not silently drop the setting (davit's philosophy, spec §1).
        #expect(throws: FlagRouter.ParseError.self) {
            _ = try FlagRouter.parse(["--privileged", "nginx"])
        }
    }

    @Test func clusteredShortFlagsRejectInteractive() throws {
        // `-it` expands to `-i -t`; -i (interactive) is explicitly unsupported
        // on this platform — the error must name that, not "unknown flag".
        do {
            _ = try FlagRouter.parse(["-it", "nginx"])
            Issue.record("expected ParseError for -i")
        } catch let e as FlagRouter.ParseError {
            #expect(e.message?.contains("interactive") == true)
        }
    }

    @Test func inlineEqualsValue() throws {
        // --env=FOO=1 spelling (docker-style) routes to the process bucket.
        let inv = try FlagRouter.parse(["--env=FOO=1", "nginx"])
        #expect(inv.process == ["--env", "FOO=1"])
    }
}
