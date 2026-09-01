import ContainerPersistence
import ContainerPlugin
import Foundation
import Logging
import SystemPackage

// MARK: - Platform install resolution (replaces CLI binary resolution)

/// Locates the container *platform* (container-apiserver + plugins). The app talks
/// to the daemon over XPC via ContainerAPIClient; these binaries are only needed to
/// bootstrap the launchd services. Resolution order:
///   1. User-configured install root (Settings)
///   2. System install (/usr/local — the official pkg)
///   3. A copy vendored inside the app bundle (Contents/Resources/vendor)
///
/// Ported verbatim from davit (Backend.swift); visibility changed to `public`
/// because GUI and CLI are separate modules that share this library.
public enum ContainerBinary {
    public static let defaultsKey = "containerInstallRoot"

    public static func resolve() -> ResolvedBinary? {
        let custom = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        var candidates: [(String, ResolvedBinary.Source)] = []
        if !custom.isEmpty { candidates.append((custom, .userConfigured)) }
        candidates.append((PlatformInstaller.managedRoot, .managed))
        candidates.append(("/usr/local", .system))
        // Homebrew keg (`brew install container`) — issue #2.
        candidates.append(("/opt/homebrew/opt/container", .homebrew))
        candidates.append(("/usr/local/opt/container", .homebrew))  // Intel brew prefix
        if let res = Bundle.main.resourceURL {
            candidates.append((res.appendingPathComponent("vendor").path, .bundled))
        }
        for (root, source) in candidates {
            let apiserver = "\(root)/bin/container-apiserver"
            if FileManager.default.isExecutableFile(atPath: apiserver) {
                return ResolvedBinary(installRoot: root, apiserverPath: apiserver, source: source)
            }
        }
        return nil
    }

    /// Must run before any ContainerAPIClient/ContainerPlugin API is touched:
    /// InstallRoot.defaultPath is computed relative to the executable, which is wrong
    /// inside an app bundle. Pin it (and let user config in app root win) via env.
    /// Also the one place swift-log gets bootstrapped (see bootstrapLogging below) —
    /// the app/CLI entry points call this before dispatching to any subcommand or the UI.
    public static func bootstrapEnvironment() {
        bootstrapLogging()
        guard ProcessInfo.processInfo.environment[InstallRoot.environmentName] == nil,
              let resolved = resolve() else { return }
        setenv(InstallRoot.environmentName, resolved.installRoot, 1)
    }

    /// `LoggingSystem.bootstrap` may run exactly once per process (a second call
    /// traps), so it happens here, unconditionally, before anything can create a
    /// `Logger`. `Backend.log` is a `static let`, lazily initialized on first
    /// access like all Swift globals — since this function runs first in the
    /// entry point and nothing above it touches `Backend.log`, that first access
    /// always happens after the bootstrap and picks up LoggingConfig.level.
    private static func bootstrapLogging() {
        let raw = ProcessInfo.processInfo.environment["DAVIT_LOG_LEVEL"]
        let (level, ok) = LoggingConfig.parseLevel(raw)
        if !ok {
            FileHandle.standardError.write(Data("DAVIT_LOG_LEVEL: unrecognized level \"\(raw ?? "")\" — using info\n".utf8))
        }
        LoggingConfig.level = level
        // A rejected value falls back to fully-default behavior (as if unset)
        // so --verbose can still bump the level to .debug — only a value that
        // actually parsed counts as the user explicitly choosing a level.
        LoggingConfig.explicitlySet = ok && raw?.isEmpty == false
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = LoggingConfig.level
            return handler
        }
    }
}

/// DAVIT_LOG_LEVEL parsing + the mutable level `bootstrapLogging`'s handler
/// factory reads from. `--verbose` bumps `level` to `.debug` before `Backend.log`
/// is ever created, unless the env var was explicit — factored out of
/// ContainerBinary so it stays pure and testable without re-bootstrapping
/// swift-log (which would trap the process).
public enum LoggingConfig {
    nonisolated(unsafe) public static var level: Logger.Level = .info
    nonisolated(unsafe) public static var explicitlySet = false

    /// nil/empty (unset) → `.info`, no warning; unrecognized → `.info` + `ok: false`
    /// so the caller can warn once. Case-insensitive over swift-log's level names.
    public static func parseLevel(_ raw: String?) -> (level: Logger.Level, ok: Bool) {
        guard let raw, !raw.isEmpty else { return (.info, true) }
        switch raw.lowercased() {
        case "trace": return (.trace, true)
        case "debug": return (.debug, true)
        case "info": return (.info, true)
        case "notice": return (.notice, true)
        case "warning": return (.warning, true)
        case "error": return (.error, true)
        case "critical": return (.critical, true)
        default: return (.info, false)
        }
    }
}

public struct ResolvedBinary: Equatable {
    public enum Source: String {
        case userConfigured = "custom path"
        case managed = "installed by Davit"
        case system = "system install"
        case homebrew = "Homebrew"
        case bundled = "bundled"
    }
    public let installRoot: String
    public let apiserverPath: String
    public let source: Source
    public var path: String { apiserverPath }

    public init(installRoot: String, apiserverPath: String, source: Source) {
        self.installRoot = installRoot
        self.apiserverPath = apiserverPath
        self.source = source
    }
}

// NOTE: `PlatformInstaller` (full installer incl. install/download/runTool)
// lives in ContainerService.swift, ported from davit's Backend.swift.
