import ArgumentParser
import OrchardCore

/// Headless entry point for the orchard container manager.
///
/// Shares the exact same OrchardCore backend as the GUI app — every
/// subcommand talks to container-apiserver over XPC, never to the
/// `container` CLI binary (spec §1). Subcommands are added feature by
/// feature; `version` is the skeleton proof that the CLI links the library.
///
/// NOTE: this file is deliberately NOT named `main.swift` — Swift forbids
/// `@main` in a top-level-code file. The `@main` attribute lives here.
@main
struct OrchardCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orchard",
        abstract: "Manage Apple's container platform",
        subcommands: [Version.self]
    )

    /// Prints the orchard version (single source of truth:
    /// `OrchardCore.versionString`).
    struct Version: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the orchard version"
        )

        func run() throws {
            print("orchard \(OrchardCore.versionString)")
        }
    }
}
