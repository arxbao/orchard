import ContainerPersistence
import ContainerPlugin
import Foundation
import Logging
import SystemPackage

// MARK: - Platform install resolution (replaces CLI binary resolution)

/// A container platform version — `major.minor.patch`, as printed by
/// `container-apiserver --version`.
///
/// Ported from davit (fix #20): resolution can no longer just take the first
/// install root on disk — an install whose major version differs from the
/// ContainerAPIClient this app links cannot be driven over XPC at all.
public struct PlatformVersion: Comparable, Hashable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        (self.major, self.minor, self.patch) = (major, minor, patch)
    }

    /// Parses a bare "1.3.1" or a whole version line
    /// ("container-apiserver version 1.3.1 (build: release, commit: a9a62e2)").
    public init?(_ raw: String) {
        guard let parsed = Self.parse(raw) else { return nil }
        self = parsed
    }

    private static func parse(_ raw: String) -> PlatformVersion? {
        let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        // The token after "version" when the line has one; otherwise anything
        // that looks like a dotted number (a commit hash never contains a dot).
        let candidates: [String]
        if let i = tokens.firstIndex(of: "version"), i + 1 < tokens.count {
            candidates = [tokens[i + 1]]
        } else {
            candidates = tokens
        }
        for token in candidates {
            let digits = token.prefix { $0.isNumber || $0 == "." }
            let parts = digits.split(separator: ".").map(String.init)
            guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { continue }
            return PlatformVersion(major, minor, parts.count > 2 ? Int(parts[2]) ?? 0 : 0)
        }
        return nil
    }

    public static func < (a: PlatformVersion, b: PlatformVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// Locates the container *platform* (container-apiserver + plugins). The app talks
/// to the daemon over XPC via ContainerAPIClient; these binaries are only needed to
/// bootstrap the launchd services. Candidate roots, in order:
///   1. User-configured install root (Settings)
///   2. The copy installed into Application Support
///   3. System install (/usr/local — the official pkg)
///   4. Homebrew kegs
///   5. A copy vendored inside the app bundle (Contents/Resources/vendor)
///
/// Order alone isn't enough. An install whose major version differs from the
/// ContainerAPIClient this app links can't be driven over XPC at all, and taking
/// the first one on disk would have us *start* a daemon we then can't talk to
/// (davit issue #20). So each candidate's version is probed, incompatible ones
/// are skipped, and when every install is incompatible we say so and offer to
/// install our own (see `Resolution`).
///
/// Ported from davit (fix #20); visibility changed to `public`.
public enum ContainerBinary {
    public static let defaultsKey = "containerInstallRoot"

    public enum Resolution {
        case resolved(ResolvedBinary)
        /// Platform installs exist, but none speak this client's protocol version.
        case incompatible([ResolvedBinary])
        case notFound
    }

    /// Every candidate root that holds an executable apiserver, version probed,
    /// in preference order.
    public static func installs() -> [ResolvedBinary] {
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
        var found: [ResolvedBinary] = []
        var seen = Set<String>()
        for (root, source) in candidates {
            let apiserver = "\(root)/bin/container-apiserver"
            guard FileManager.default.isExecutableFile(atPath: apiserver),
                  seen.insert(apiserver).inserted else { continue }
            found.append(ResolvedBinary(
                installRoot: root,
                apiserverPath: apiserver,
                source: source,
                version: probeVersion(apiserverPath: apiserver)))
        }
        return found
    }

    public static func resolution() -> Resolution { choose(from: installs()) }

    /// The pure half of `resolution()`: which install on disk to drive.
    public static func choose(from installs: [ResolvedBinary]) -> Resolution {
        guard !installs.isEmpty else { return .notFound }
        // An exact match for the client this app links is always the safest bet,
        // wherever it sits in the candidate order.
        if let exact = installs.first(where: { $0.version == PlatformInstaller.pinned }) {
            return .resolved(exact)
        }
        // Otherwise the first candidate this client can actually talk to. An
        // unreadable version counts as usable — that's the pre-probe behavior,
        // and refusing to start over a missing `--version` would be worse.
        if let usable = installs.first(where: { $0.version.map(isCompatible) ?? true }) {
            return .resolved(usable)
        }
        return .incompatible(installs)
    }

    public static func resolve() -> ResolvedBinary? {
        guard case .resolved(let binary) = resolution() else { return nil }
        return binary
    }

    /// We drive the daemon through ContainerAPIClient `pinnedVersion`, and the
    /// XPC contract only holds within a major version — a 0.x daemon doesn't even
    /// answer the health check a 1.x client sends (davit issue #20).
    public static func isCompatible(_ version: PlatformVersion) -> Bool {
        version.major == PlatformInstaller.pinned.major
    }

    /// Why no platform was resolved, in the user's terms — naming the installs
    /// that were rejected, so the message isn't a bare "not found" on a machine
    /// that visibly has `container` on it.
    public static func unavailableMessage(_ resolution: Resolution) -> String {
        switch resolution {
        case .resolved:
            return ""
        case .incompatible(let installs):
            let list = installs
                .map { "container \($0.version?.description ?? "?") at \($0.installRoot)" }
                .joined(separator: ", ")
            return """
                \(list) — Orchard speaks container \(PlatformInstaller.pinnedVersion) and can't drive \
                that version. Install a matching platform: the welcome screen offers one click \
                (no administrator rights), or run `orchard platform install`. Your existing install is \
                left alone.
                """
        case .notFound:
            return "container platform not found — install it from https://github.com/apple/container/releases or vendor it into the app"
        }
    }

    /// `container-apiserver --version` at `path`, or nil when it can't be read.
    /// Cached: resolution runs on every refresh tick, the probe forks a process,
    /// and install roots don't change under a running app except through
    /// `PlatformInstaller`, which invalidates.
    public static func probeVersion(apiserverPath path: String) -> PlatformVersion? {
        cacheLock.lock()
        let cached = versionCache[path]
        cacheLock.unlock()
        if let cached { return cached }
        let version = readVersion(apiserverPath: path)
        cacheLock.lock()
        versionCache[path] = version
        cacheLock.unlock()
        return version
    }

    public static func invalidateVersionCache() {
        cacheLock.lock()
        versionCache.removeAll()
        cacheLock.unlock()
    }

    private nonisolated(unsafe) static var versionCache: [String: PlatformVersion?] = [:]
    private static let cacheLock = NSLock()

    private static func readVersion(apiserverPath path: String) -> PlatformVersion? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // This can run on the main actor (refreshAll) — a wedged binary must not
        // freeze the UI. Terminating closes the pipe, so the read returns and the
        // non-zero status makes it an unknown version.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        defer { watchdog.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return PlatformVersion(String(decoding: data, as: UTF8.self))
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
        case managed = "installed by Orchard"
        case system = "system install"
        case homebrew = "Homebrew"
        case bundled = "bundled"
    }
    public let installRoot: String
    public let apiserverPath: String
    public let source: Source
    /// nil when `container-apiserver --version` couldn't be read.
    public var version: PlatformVersion?
    public var path: String { apiserverPath }
    /// "system install · 1.3.1" — source plus version, for the UI.
    public var label: String { version.map { "\(source.rawValue) · \($0)" } ?? source.rawValue }

    public init(installRoot: String, apiserverPath: String, source: Source, version: PlatformVersion? = nil) {
        self.installRoot = installRoot
        self.apiserverPath = apiserverPath
        self.source = source
        self.version = version
    }
}

// NOTE: `PlatformInstaller` (full installer incl. install/download/runTool)
// lives in ContainerService.swift, ported from davit's Backend.swift.
