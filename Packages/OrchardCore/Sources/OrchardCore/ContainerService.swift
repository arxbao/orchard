import ContainerAPIClient
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import Foundation
import Logging
import MachineAPIClient
import SystemPackage
import TerminalProgress

// MARK: - Shared config / logging

/// Shared logging + config helpers. `log` is a `static let`, lazily
/// initialized on first access — entry points MUST call
/// `ContainerBinary.bootstrapEnvironment()` first so LoggingSystem is
/// bootstrapped before this is ever touched (a second bootstrap traps).
enum Backend {
    static let log = Logger(label: "dev.wouter.davit")

    static func systemConfig() async throws -> ContainerSystemConfig {
        try await ConfigurationLoader.load(
            configurationFiles: [
                ConfigurationLoader.configurationFile(in: ApplicationRoot.path, of: .appRoot),
                ConfigurationLoader.configurationFile(in: InstallRoot.path, of: .installRoot),
            ])
    }

    static func prettyJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Typed service API (same facade as before, now XPC-backed)

/// down, recreate). Used to tell an expected running->stopped transition from
/// an unexpected one (crash, OOM, external kill) for notifications.
final class ExpectedStops: @unchecked Sendable {
    static let shared = ExpectedStops()
    private let lock = NSLock()
    private var stamps: [String: Date] = [:]

    func mark(_ id: String) {
        lock.lock(); stamps[id] = Date(); lock.unlock()
    }

    /// True (and consumes the mark) when the stop was requested in the last
    /// couple of minutes — long enough for a slow graceful stop to complete.
    func consume(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let at = stamps.removeValue(forKey: id) else { return false }
        return Date().timeIntervalSince(at) < 120
    }
}

enum ContainerService {
    // MARK: Listing

    static func listContainers() async throws -> [ContainerRecord] {
        let snapshots = try await ContainerClient().list()
        return snapshots
            .map(ContainerRecord.init(snapshot:))
            // Machine backing containers are infrastructure; they live in the
            // Machines section (the CLI hides them from `container list` too).
            .filter { $0.configuration.labels?["com.apple.container.plugin"] != "machine" }
            // Volume-browser helpers are infrastructure too (see VolumeBrowser).
            .filter { $0.configuration.labels?["com.davit.volume-browser"] == nil }
            // The buildkit builder VM is infrastructure the build flow manages
            // on its own — hide it like we already hide infra images and machine
            // backings, so it isn't listed, counted, or acted on (e.g. Export,
            // which fails on its special filesystem: "deep extents").
            .filter { !isInfraImage($0.imageReference) }
    }

    static func listImages() async throws -> [ImageRecord] {
        let images = try await ClientImage.list()
        var records: [ImageRecord] = []
        for image in images {
            // Hide infrastructure images (vminit, builder) like the CLI does.
            if isInfraImage(image.reference) { continue }
            records.append(await ImageRecord(client: image))
        }
        return records
    }

    static func isInfraImage(_ reference: String) -> Bool {
        reference.contains("/containerization/vminit") || reference.contains("/container-builder-shim/")
    }

    /// Whether `reference` already resolves to a locally present image AT the
    /// requested platform variant — the same two-step check `ClientImage.fetch`
    /// does internally (reference lookup, then `match.config(for:)` to confirm
    /// the specific platform's config is present) before falling back to a
    /// pull. Used by `davit run --pull never` to fail fast instead of silently
    /// degrading to `missing`'s pull-if-absent behavior. `managementArgs` are
    /// the raw `--platform`/`--os`/`--arch` flags (docker-style, may be empty)
    /// so this matches exactly what the create path would request; only a
    /// `.notFound` from either step means "not present" — any other error
    /// (unreachable registry config, corrupt store, ...) is rethrown rather
    /// than masked as a plain "false".
    static func imageExists(_ reference: String, managementArgs: [String] = []) async throws -> Bool {
        let config = try await Backend.systemConfig()
        do {
            let image = try await ClientImage.get(reference: reference, containerSystemConfig: config)
            let management = try Flags.Management.parse(managementArgs)
            let platform = try DefaultPlatform.resolveWithDefaults(
                platform: management.platform, os: management.os, arch: management.arch, log: Backend.log)
            _ = try await image.config(for: platform)
            return true
        } catch let error as ContainerizationError where error.isCode(.notFound) {
            return false
        }
    }

    static func listNetworks() async throws -> [NetworkRecord] {
        try await NetworkClient().list().map(NetworkRecord.init(resource:))
    }

    static func listVolumes() async throws -> [VolumeRecord] {
        try await ClientVolume.list().map(VolumeRecord.init(configuration:))
    }

    static func stats(for ids: [String]) async throws -> [StatsRecord] {
        let client = ContainerClient()
        return await withTaskGroup(of: StatsRecord?.self) { group in
            for id in ids {
                group.addTask {
                    guard let s = try? await client.stats(id: id) else { return nil }
                    return StatsRecord(stats: s)
                }
            }
            var out: [StatsRecord] = []
            for await record in group {
                if let record { out.append(record) }
            }
            return out
        }
    }

    /// Per-container disk space used (writable layer), in bytes, keyed by id.
    static func containerDiskUsage(for ids: [String]) async -> [String: Int64] {
        let client = ContainerClient()
        return await withTaskGroup(of: (String, Int64)?.self) { group in
            for id in ids {
                group.addTask {
                    guard let bytes = try? await client.diskUsage(id: id) else { return nil }
                    return (id, Int64(bytes))
                }
            }
            var out: [String: Int64] = [:]
            for await entry in group {
                if let (id, bytes) = entry { out[id] = bytes }
            }
            return out
        }
    }

    static func diskUsage() async throws -> DiskUsage {
        let df = try await ClientDiskUsage.get()
        func map(_ u: ResourceUsage) -> DiskUsage.Section {
            DiskUsage.Section(
                total: u.total, active: u.active,
                sizeInBytes: Int64(u.sizeInBytes), reclaimable: Int64(u.reclaimable))
        }
        return DiskUsage(containers: map(df.containers), images: map(df.images), volumes: map(df.volumes))
    }

    // MARK: Container lifecycle

    /// `retainExitCode` hands the bootstrap process to `ComposeExitCodes` so the
    /// init exit code can be awaited later (snapshots don't carry it).
    static func start(_ id: String, retainExitCode: Bool = false) async throws {
        let client = ContainerClient()
        let container = try await client.get(id: id)
        guard container.status != .running else { return }
        let io = try ProcessIO.create(tty: container.configuration.initProcess.terminal, interactive: false, detach: true)
        do {
            // Mirrors apple's own ContainerRun/ContainerStart: the daemon-side
            // ssh-forwarding lookup (RuntimeService.sshAuthSocketHostUrl) only
            // fires when the container's own config has `ssh` set, so handing
            // this along unconditionally is a no-op for every non-ssh container.
            var dynamicEnv: [String: String] = [:]
            if let sshAuthSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
                dynamicEnv["SSH_AUTH_SOCK"] = sshAuthSock
            }
            let process = try await client.bootstrap(id: id, stdio: io.stdio, dynamicEnv: dynamicEnv)
            // Register BEFORE start: a fast one-shot can exit — and the
            // apiserver reap its runtime client — before a wait issued
            // afterwards lands, losing the exit code (see ComposeExitCodes).
            if retainExitCode { await ComposeExitCodes.shared.register(id: id, process: process) }
            try await process.start()
            try io.closeAfterStart()
        } catch {
            try? io.close()
            try? await client.stop(id: id)
            throw CLIError.wrap("start \(id)", error)
        }
    }

    /// Defaults mirror the platform's stop options (5s grace, SIGTERM).
    /// Compose down passes stop_grace_period / stop_signal through here; the
    /// signal is a name or number ("SIGUSR1", "USR1", "10") parsed daemon-side.
    static func stop(_ id: String, timeoutSeconds: Int32 = 5, signal: String? = nil) async throws {
        ExpectedStops.shared.mark(id)
        try await ContainerClient().stop(
            id: id, opts: ContainerStopOptions(timeoutInSeconds: timeoutSeconds, signal: signal))
    }

    static func kill(_ id: String) async throws {
        ExpectedStops.shared.mark(id)
        try await ContainerClient().kill(id: id, signal: "KILL")
    }

    static func restart(_ id: String) async throws {
        try? await stop(id)
        try await start(id)
    }

    static func delete(_ id: String, force: Bool) async throws {
        ExpectedStops.shared.mark(id)
        try await ContainerClient().delete(id: id, force: force)
    }

    /// Export a container's filesystem to a tar archive on the host (container
    /// 1.2+). Works on running or stopped containers.
    static func exportContainer(_ id: String, to archive: URL) async throws {
        do {
            try await ContainerClient().export(id: id, archive: archive)
        } catch {
            // Some filesystems (notably the builder VM's) use sparse ext4
            // extents the archiver can't walk — surface that plainly instead
            // of the raw "deep extents are not supported".
            if String(describing: error).contains("deep extents") {
                throw CLIError(command: "export \(id)",
                    message: "This container's filesystem can't be exported — it uses a sparse format the archiver doesn't support. Regular application containers export fine.")
            }
            throw CLIError.wrap("export \(id)", error)
        }
    }

    static func pruneContainers() async throws {
        let client = ContainerClient()
        for snapshot in try await client.list() where snapshot.status == .stopped {
            try? await client.delete(id: snapshot.id, force: false)
        }
    }

    static func stopAll() async throws {
        let client = ContainerClient()
        for snapshot in try await client.list() where snapshot.status == .running {
            ExpectedStops.shared.mark(snapshot.id)
            try? await client.stop(id: snapshot.id)
        }
    }

    // MARK: Run (create + detached start)

    static func runContainer(
        image: String,
        name: String?,
        processArgs: [String],
        managementArgs: [String],
        resourceArgs: [String],
        commandArgs: [String],
        autoRemove: Bool = false,
        retainExitCode: Bool = false,
        progressUpdate: @escaping ProgressUpdateHandler = { _ in }
    ) async throws {
        do {
            // The run path auto-pulls missing images; stage helper credentials first.
            await DockerCredentialHelpers.refreshCredentials(forReference: image)
            let config = try await Backend.systemConfig()
            let id = Utility.createContainerID(name: name?.isEmpty == true ? nil : name)
            // container 1.3 replaced Utility.validEntityName (throwing) with
            // ManagedContainer.nameValid (Bool).
            guard ManagedContainer.nameValid(id) else {
                throw CLIError(command: "run", message: "\"\(id)\" is not a valid container name (letters, digits, and . _ - only)")
            }

            let process = try Flags.Process.parse(processArgs)
            let management = try Flags.Management.parse(managementArgs)
            let resource = try Flags.Resource.parse(resourceArgs)
            let registry = try Flags.Registry.parse([])
            let imageFetch = try Flags.ImageFetch.parse([])

            let (configuration, kernel, initImage) = try await Utility.containerConfigFromFlags(
                id: id,
                image: image,
                arguments: commandArgs,
                process: process,
                management: management,
                resource: resource,
                registry: registry,
                imageFetch: imageFetch,
                containerSystemConfig: config,
                progressUpdate: progressUpdate,
                log: Backend.log
            )

            let client = ContainerClient()
            try await client.create(
                configuration: configuration,
                options: ContainerCreateOptions(autoRemove: autoRemove),
                kernel: kernel,
                initImage: initImage
            )
            try await start(id, retainExitCode: retainExitCode)
        } catch let e as CLIError {
            throw e
        } catch {
            throw CLIError.wrap("run \(image)", error)
        }
    }

    // MARK: Images

    static func pullImage(_ reference: String, progress: @escaping @Sendable ([ProgressUpdateEvent]) async -> Void) async throws {
        do {
            await DockerCredentialHelpers.refreshCredentials(forReference: reference)
            let config = try await Backend.systemConfig()
            _ = try await ClientImage.pull(
                reference: reference,
                containerSystemConfig: config,
                progressUpdate: progress
            )
        } catch {
            throw CLIError.wrap("pull \(reference)", error)
        }
    }

    static func deleteImage(_ name: String) async throws {
        do {
            try await ClientImage.delete(reference: name, garbageCollect: true)
        } catch {
            throw CLIError.wrap("delete image \(name)", error)
        }
    }

    static func pruneImages(all: Bool) async throws {
        do {
            let inUse = Set(try await ContainerClient().list().map { $0.configuration.image.reference })
            for image in try await ClientImage.list() {
                let ref = image.reference
                if isInfraImage(ref) || inUse.contains(ref) { continue }
                try? await ClientImage.delete(reference: ref, garbageCollect: false)
            }
            _ = try await ClientImage.cleanUpOrphanedBlobs()
        } catch {
            throw CLIError.wrap("prune images", error)
        }
    }

    static func tagImage(_ source: String, _ target: String) async throws {
        do {
            let config = try await Backend.systemConfig()
            let image = try await ClientImage.get(reference: source, containerSystemConfig: config)
            let normalized = try ClientImage.normalizeReference(target, containerSystemConfig: config)
            _ = try await image.tag(new: normalized)
        } catch {
            throw CLIError.wrap("tag \(source)", error)
        }
    }

    // MARK: Volumes

    static func createVolume(name: String, size: String?) async throws {
        do {
            var opts: [String: String] = [:]
            if let size, !size.isEmpty { opts["size"] = size }
            _ = try await ClientVolume.create(name: name, driverOpts: opts)
        } catch {
            throw CLIError.wrap("create volume \(name)", error)
        }
    }

    static func deleteVolume(_ name: String) async throws {
        do {
            try await ClientVolume.delete(name: name)
        } catch {
            throw CLIError.wrap("delete volume \(name)", error)
        }
    }

    static func pruneVolumes() async throws {
        let used = usedVolumeNames(in: (try? await ContainerClient().list()) ?? [])
        for volume in try await ClientVolume.list() where !used.contains(volume.name) {
            try? await ClientVolume.delete(name: volume.name)
        }
    }

    static func usedVolumeNames(in snapshots: [ContainerSnapshot]) -> Set<String> {
        var used = Set<String>()
        for snapshot in snapshots {
            for mount in snapshot.configuration.mounts {
                if let name = VolumeRecord.volumeName(fromSource: mount.source) {
                    used.insert(name)
                }
            }
        }
        return used
    }

    // MARK: Networks

    static func createNetwork(name: String, subnet: String?, internal isInternal: Bool) async throws {
        do {
            let cidr: CIDRv4? = try subnet.flatMap { $0.isEmpty ? nil : try CIDRv4($0) }
            let configuration = try NetworkConfiguration(
                name: name,
                mode: isInternal ? .hostOnly : .nat,
                ipv4Subnet: cidr,
                plugin: "container-network-vmnet"
            )
            _ = try await NetworkClient().create(configuration: configuration)
        } catch let e as CLIError {
            throw e
        } catch {
            throw CLIError.wrap("create network \(name)", error)
        }
    }

    static func deleteNetwork(_ name: String) async throws {
        do {
            try await NetworkClient().delete(id: name)
        } catch {
            throw CLIError.wrap("delete network \(name)", error)
        }
    }

    static func pruneNetworks() async throws {
        let snapshots = (try? await ContainerClient().list()) ?? []
        var attached = Set<String>()
        for snapshot in snapshots {
            for net in snapshot.configuration.networks {
                attached.insert(net.network)
            }
        }
        for network in try await NetworkClient().list() where !network.isBuiltin && !attached.contains(network.name) {
            try? await NetworkClient().delete(id: network.name)
        }
    }

    // MARK: System

    static func systemState() async throws -> SystemState {
        do {
            let health = try await ClientHealthCheck.ping(timeout: .seconds(3))
            return .running(version: health.apiServerVersion)
        } catch {
            return .stopped
        }
    }

    /// True when the daemon has a default guest kernel for this host arch.
    /// When false, `run` fails with "default kernel not configured" (issue #16)
    /// — which happens when the daemon was started outside Davit (CLI/official
    /// installer), so Davit's start-time kernel provisioning never ran.
    static func hasDefaultKernel() async -> Bool {
        (try? await ClientKernel.getDefaultKernel(for: .current)) != nil
    }

    /// Download + install the recommended guest kernel — the manual equivalent
    /// of what `systemStart` does. Idempotent (no-op if one already exists).
    static func configureDefaultKernel() async throws {
        do {
            let config = try await Backend.systemConfig()
            try await SystemController.ensureKernel(config: config)
        } catch let e as CLIError {
            throw e
        } catch {
            throw CLIError.wrap("configure kernel", error)
        }
    }

    static func systemStart() async throws {
        guard let resolved = ContainerBinary.resolve() else {
            throw CLIError(command: "system start", message: "container platform not found — install it from https://github.com/apple/container/releases or vendor it into the app")
        }
        do {
            try await SystemController.start(resolved: resolved)
        } catch let e as CLIError {
            throw e
        } catch {
            if let friendly = friendlyStartError(String(describing: error)) {
                throw CLIError(command: "system start", message: friendly)
            }
            throw CLIError.wrap("system start", error)
        }
    }

    /// Translate a cryptic platform startup error into an actionable one.
    /// Returns nil when unrecognized (caller keeps the raw message).
    static func friendlyStartError(_ raw: String) -> String? {
        // A health-check field failing to decode means the running daemon is a
        // different (older) container-apiserver than the version Davit ships —
        // typically a pre-existing `container` install answering instead of
        // Davit's own. (apple/container issue: the client hard-requires fields
        // its own health reply calls optional.)
        if raw.contains("in health check"), raw.contains("decode") {
            return """
            A different version of the container platform is running than Davit expects \
            (Davit ships \(PlatformInstaller.pinnedVersion)). This usually means an older \
            `container` was already installed — the official package or Homebrew — and its \
            daemon is the one answering. Stop it with `container system stop` (or reboot), \
            then start services again so Davit's own \(PlatformInstaller.pinnedVersion) \
            platform takes over.
            """
        }
        return nil
    }

    static func systemStop() async throws {
        do {
            try await SystemController.stop()
        } catch {
            throw CLIError.wrap("system stop", error)
        }
    }

    static func properties() async throws -> String {
        let config = try await Backend.systemConfig()
        return Backend.prettyJSON(config)
    }

    // MARK: Inspection

    /// A built image layer for the detail view: size, digest, and the
    /// Dockerfile-ish command that produced it (from the config history).
    struct ImageLayer: Identifiable {
        let index: Int
        let sizeBytes: Int64
        let digest: String
        let createdBy: String?
        var id: Int { index }
    }

    /// Layers of an image for the host platform, zipped with the non-empty
    /// history entries (empty_layer history items are metadata-only and have
    /// no matching layer blob).
    static func imageLayers(_ reference: String) async throws -> [ImageLayer] {
        do {
            let config = try await Backend.systemConfig()
            let image = try await ClientImage.get(reference: reference, containerSystemConfig: config)
            let platform = ContainerizationOCI.Platform(
                arch: Arch.hostArchitecture().rawValue, os: "linux")
            let manifest = try await image.manifest(for: platform)
            let history = (try? await image.config(for: platform))?.history ?? []
            // Pair each real layer with the next non-empty history command,
            // in order. History has extra empty_layer entries (ENV, CMD, …).
            let commands = history.filter { $0.emptyLayer != true }.map(\.createdBy)
            return manifest.layers.enumerated().map { i, layer in
                ImageLayer(
                    index: i,
                    sizeBytes: layer.size,
                    digest: layer.digest,
                    createdBy: i < commands.count ? commands[i] : nil)
            }
        } catch {
            throw CLIError.wrap("image layers \(reference)", error)
        }
    }

    static func inspectRaw(_ kind: String, _ id: String) async throws -> String {
        switch kind {
        case "container":
            let snapshot = try await ContainerClient().get(id: id)
            return Backend.prettyJSON(snapshot)
        case "image":
            let config = try await Backend.systemConfig()
            let image = try await ClientImage.get(reference: id, containerSystemConfig: config)
            let index = try? await image.index()
            struct Inspect: Encodable {
                let description: ImageDescription
                let index: ContainerizationOCI.Index?
            }
            return Backend.prettyJSON(Inspect(description: image.description, index: index))
        case "machine":
            let snapshot = try await MachineClient().inspect(id: id)
            return Backend.prettyJSON(snapshot)
        case "network":
            let network = try await NetworkClient().get(id: id)
            return Backend.prettyJSON(network.configuration)
        case "volume":
            let volume = try await ClientVolume.inspect(id)
            return Backend.prettyJSON(VolumeRecord(configuration: volume))
        default:
            return "{}"
        }
    }
}

// MARK: - System service bootstrap (what `container system start/stop` does, in-process)

enum SystemController {
    static let apiServerLabel = "com.apple.container.apiserver"
    static let labelPrefix = "com.apple.container."

    static func start(resolved: ResolvedBinary) async throws {
        let appRoot = ApplicationRoot.path
        try? ConfigurationLoader.copyConfigurationToReadOnly(to: appRoot)

        // Resolve symlinks: launchd + amfid validate signatures against the real path.
        let apiserverPath = try FilePath(resolved.apiserverPath).resolvingSymlinks()

        let apiServerDataPath = appRoot.appending(FilePath.Component("apiserver"))
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: apiServerDataPath.string), withIntermediateDirectories: true)

        var env = PluginLoader.filterEnvironment()
        env[ApplicationRoot.environmentName] = appRoot.string
        env[InstallRoot.environmentName] = resolved.installRoot

        let plist = LaunchPlist(
            label: apiServerLabel,
            arguments: [apiserverPath.string, "start"],
            environment: env,
            limitLoadToSessionType: [.Aqua, .Background, .System],
            runAtLoad: true,
            machServices: [apiServerLabel]
        )
        let plistPath = apiServerDataPath.appending(FilePath.Component("apiserver.plist"))
        try plist.encode().write(to: URL(fileURLWithPath: plistPath.string))
        try ServiceManager.register(plistPath: plistPath.string)

        _ = try await ClientHealthCheck.ping(timeout: .seconds(20))

        // Make sure the init filesystem and default kernel exist (non-interactive).
        let config = try await Backend.systemConfig()
        await ensureInitImage(config: config)
        try await ensureKernel(config: config)
    }

    static func stop() async throws {
        let domain = try ServiceManager.getDomainString()
        let fullLabel = "\(domain)/\(apiServerLabel)"

        if (try? await ClientHealthCheck.ping(timeout: .seconds(3))) != nil {
            try? await ContainerService.stopAll()
            // give containers a moment to exit before tearing the daemon down
            for _ in 0..<10 {
                let running = (try? await ContainerClient().list())?.contains { $0.status == .running } ?? false
                if !running { break }
                try? await Task.sleep(for: .seconds(1))
            }
            try? ServiceManager.deregister(fullServiceLabel: fullLabel)
        }

        try ServiceManager.enumerate()
            .filter { $0.hasPrefix(labelPrefix) && $0 != apiServerLabel }
            .forEach { try? ServiceManager.deregister(fullServiceLabel: "\(domain)/\($0)") }
    }

    private static func ensureInitImage(config: ContainerSystemConfig) async {
        let reference = config.vminit.image
        if (try? await ClientImage.get(reference: reference, containerSystemConfig: config)) != nil { return }
        _ = try? await ClientImage.pull(reference: reference, containerSystemConfig: config)
    }

    static func ensureKernel(config: ContainerSystemConfig) async throws {
        if (try? await ClientKernel.getDefaultKernel(for: .current)) != nil { return }
        // Download the recommended kernel archive and install it (mirrors --enable-kernel-install).
        let (tempURL, _) = try await URLSession.shared.download(from: config.kernel.url)
        let tarPath = tempURL.path + ".tar.zst"
        try? FileManager.default.moveItem(atPath: tempURL.path, toPath: tarPath)
        defer { try? FileManager.default.removeItem(atPath: tarPath) }
        try await ClientKernel.installKernelFromTar(
            tarFile: tarPath,
            kernelFilePath: config.kernel.binaryPath,
            platform: .current,
            force: true
        )
    }
}
import Foundation
import ContainerizationExtras

enum SystemConfigStore {
    struct Snapshot {
        /// section → key → scalar (from JSON encoding of ContainerSystemConfig)
        var effective: [String: [String: Any]]
        var defaults: [String: [String: Any]]
    }

    static var homeConfigPath: FilePath {
        ConfigurationLoader.configurationFile(.home)
    }

    static func load() async throws -> Snapshot {
        let effective = try await Backend.systemConfig()
        let defaults: ContainerSystemConfig
        do {
            defaults = try await ConfigurationLoader.load(
                configurationFiles: [ConfigurationLoader.configurationFile(in: InstallRoot.path, of: .installRoot)])
        } catch {
            defaults = ContainerSystemConfig()
        }
        return Snapshot(effective: try dictionary(of: effective), defaults: try dictionary(of: defaults))
    }

    /// Persist `edited` (full effective values): diffs against defaults, writes TOML,
    /// validates, publishes to the app root so client-side loads pick it up immediately.
    static func save(edited: [String: [String: Any]], defaults: [String: [String: Any]]) async throws {
        var toml = "# User overrides for Apple's container platform.\n# Managed by Davit — edits made here are preserved only for [plugin.*] sections.\n"
        var wroteAny = false
        for section in edited.keys.sorted() {
            guard let values = edited[section] else { continue }
            let defaultValues = defaults[section] ?? [:]
            var lines: [String] = []
            for key in values.keys.sorted() {
                let value = values[key]!
                if value is NSNull { continue }
                if let def = defaultValues[key], scalarEqual(def, value) { continue }
                guard let rendered = tomlScalar(value) else { continue }
                lines.append("\(key) = \(rendered)")
            }
            if !lines.isEmpty {
                toml += "\n[\(section)]\n" + lines.joined(separator: "\n") + "\n"
                wroteAny = true
            }
        }

        // Preserve [plugin.*] sections from the existing user file.
        let path = homeConfigPath.string
        if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            let pluginBlocks = pluginSections(in: existing)
            if !pluginBlocks.isEmpty {
                toml += "\n" + pluginBlocks.joined(separator: "\n") + "\n"
                wroteAny = true
            }
        }

        let fm = FileManager.default
        if !wroteAny {
            // No overrides at all: remove the user file so defaults fully apply.
            try? fm.removeItem(atPath: path)
            // container 1.3's copyConfigurationToReadOnly is a no-op when the
            // source is missing, so removing the home file alone leaves the
            // published read-only copy (<appRoot>/config/config.toml) stale and
            // the daemon keeps reading the old override. Clear that copy too.
            try? fm.removeItem(atPath: ConfigurationLoader.configurationFile(.appRoot).string)
        } else {
            // Validate through the real loader before committing.
            let tempPath = fm.temporaryDirectory.appendingPathComponent("davit-config-\(UUID().uuidString).toml").path
            try toml.write(toFile: tempPath, atomically: true, encoding: .utf8)
            defer { try? fm.removeItem(atPath: tempPath) }
            do {
                _ = try await ConfigurationLoader.load(configurationFiles: [FilePath(tempPath)])
            } catch {
                throw CLIError(command: "save settings", message: "invalid configuration: \(error)")
            }
            try fm.createDirectory(
                atPath: homeConfigPath.removingLastComponent().string, withIntermediateDirectories: true)
            try toml.write(toFile: path, atomically: true, encoding: .utf8)
        }

        // Publish to <appRoot>/config/config.toml (normally done at service start).
        try ConfigurationLoader.copyConfigurationToReadOnly()
    }

    // MARK: helpers

    private static func dictionary(of config: ContainerSystemConfig) throws -> [String: [String: Any]] {
        let data = try JSONEncoder().encode(config)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return obj.mapValues { $0 as? [String: Any] ?? [:] }
    }

    private static func scalarEqual(_ a: Any, _ b: Any) -> Bool {
        (a as? NSObject)?.isEqual(b) ?? false
    }

    private static func tomlScalar(_ value: Any) -> String? {
        switch value {
        case let n as NSNumber:
            // NSNumber bridges bools too; distinguish via the ObjC type encoding.
            if String(cString: n.objCType) == "c" { return n.boolValue ? "true" : "false" }
            if n.doubleValue == n.doubleValue.rounded() { return "\(n.int64Value)" }
            return "\(n.doubleValue)"
        case let s as String:
            let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        default:
            return nil
        }
    }

    private static func pluginSections(in toml: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        var inPlugin = false
        for line in toml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if inPlugin, !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
                inPlugin = trimmed.hasPrefix("[plugin.") || trimmed.hasPrefix("[plugin]")
                current = inPlugin ? [line] : []
            } else if inPlugin {
                current.append(line)
            }
        }
        if inPlugin, !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
        return blocks
    }
}

// MARK: - In-app platform installer

/// Downloads Apple's signed installer package for the container platform, extracts
/// its payload into an app-managed install root (no admin rights required, unlike
/// the official installer), verifies code signatures, and activates it. The managed
/// root then hosts the launchd services exactly like a /usr/local install.
enum PlatformInstaller {
    /// Must match the ContainerAPIClient version this app links (Package.swift pin).
    static let pinnedVersion = "1.3.0"

    static var managedRoot: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("dev.wouter.davit/platform/\(pinnedVersion)").path
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: managedRoot + "/bin/container-apiserver")
    }

    /// progress: stage text + download fraction (nil while not downloading / size unknown)
    static func install(progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("davit-install-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        progress("Downloading container \(pinnedVersion)…", 0)
        let url = URL(string: "https://github.com/apple/container/releases/download/\(pinnedVersion)/container-\(pinnedVersion)-installer-signed.pkg")!
        let pkgPath = work.appendingPathComponent("container.pkg")
        try await downloadWithProgress(from: url, to: pkgPath) { fraction, receivedMB, totalMB in
            if let totalMB {
                progress(String(format: "Downloading container \(pinnedVersion)… %.0f of %.0f MB", receivedMB, totalMB), fraction)
            } else {
                progress(String(format: "Downloading container \(pinnedVersion)… %.0f MB", receivedMB), nil)
            }
        }

        progress("Extracting installer payload…", nil)
        let expanded = work.appendingPathComponent("expanded")
        try await runTool("/usr/sbin/pkgutil", ["--expand-full", pkgPath.path, expanded.path])
        guard let payload = findPayload(in: expanded) else {
            throw CLIError(command: "platform install", message: "could not locate Payload in the installer package")
        }

        progress("Verifying code signatures…", nil)
        let stagedAPIServer = payload.appendingPathComponent("bin/container-apiserver").path
        guard fm.isExecutableFile(atPath: stagedAPIServer) else {
            throw CLIError(command: "platform install", message: "payload is missing bin/container-apiserver")
        }
        try await runTool("/usr/bin/codesign", ["--verify", "--strict", stagedAPIServer])

        progress("Installing to Application Support…", nil)
        // Clear quarantine so launchd can execute the extracted binaries.
        _ = try? await runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", payload.path])
        let root = managedRoot
        if fm.fileExists(atPath: root) { try fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: (root as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.copyItem(atPath: payload.path, toPath: root)

        guard isInstalled else {
            throw CLIError(command: "platform install", message: "installation completed but bin/container-apiserver is not executable")
        }
        // Point resolution at the managed root before any library API caches paths.
        setenv(InstallRoot.environmentName, root, 1)
        progress("Installed to \(root)", nil)
    }

    /// Streams a download to disk, reporting (fraction?, receivedMB, totalMB?) as it goes.
    static func downloadWithProgress(
        from url: URL,
        to destination: URL,
        report: @escaping @Sendable (Double?, Double, Double?) -> Void
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CLIError(command: "platform install", message: "download failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let total = response.expectedContentLength  // -1 when unknown
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 17)
        var received: Int64 = 0
        var lastReported: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 17 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                // report every ~2 MB to keep UI updates cheap
                if received - lastReported >= 1 << 21 {
                    lastReported = received
                    let mb = Double(received) / 1_048_576
                    if total > 0 {
                        report(Double(received) / Double(total), mb, Double(total) / 1_048_576)
                    } else {
                        report(nil, mb, nil)
                    }
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        let mb = Double(received) / 1_048_576
        report(1.0, mb, total > 0 ? Double(total) / 1_048_576 : mb)
    }

    /// Removes the managed install (containers/images are unaffected — they live in
    /// the shared app root under com.apple.container).
    static func removeManaged() throws {
        try FileManager.default.removeItem(atPath: managedRoot)
    }

    private static func findPayload(in dir: URL) -> URL? {
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
        while let item = enumerator?.nextObject() as? URL {
            if item.lastPathComponent == "Payload",
               (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
               fm.fileExists(atPath: item.appendingPathComponent("bin").path) {
                return item
            }
        }
        return nil
    }

    /// Minimal runner for system tools (pkgutil/codesign/xattr/osascript) — not the
    /// container CLI. Output goes to a temp file rather than a pipe: some of these
    /// tools spawn XPC helpers (e.g. CSExattrCryptoService) that inherit a pipe's
    /// write end and outlive the tool, so pipe-EOF never arrives and reads hang.
    /// File-backed output + termination-driven completion has no such failure mode.
    @discardableResult
    static func runTool(_ path: String, _ args: [String]) async throws -> String {
        let fm = FileManager.default
        let outURL = fm.temporaryDirectory.appendingPathComponent("davit-tool-\(UUID().uuidString).out")
        fm.createFile(atPath: outURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)
        defer {
            try? outHandle.close()
            try? fm.removeItem(at: outURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = outHandle
        process.standardError = outHandle
        process.standardInput = FileHandle.nullDevice

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in cont.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }

        let output = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        if process.terminationStatus != 0 {
            throw CLIError(
                command: ([path] + args).joined(separator: " "),
                message: output.trimmingCharacters(in: .whitespacesAndNewlines),
                exitCode: process.terminationStatus)
        }
        return output
    }
}

// MARK: - Shell command installer (`container` in /usr/local/bin)

/// Mimics the system install's shell experience for a Davit-managed platform:
/// writes a wrapper at /usr/local/bin/container that pins CONTAINER_INSTALL_ROOT
/// to the managed root and execs the real CLI. A plain symlink would be wrong —
/// the CLI derives its install root from the (unresolved) executable path and
import Foundation

extension ContainerService {
    struct RecreatePrefill {
        /// What the user originally passed after the image (entrypoint/CMD subtracted).
        var commandArgs: [String] = []
        /// Env vars that aren't part of the image config (i.e. user-supplied).
        var customEnv: [String] = []
    }

    /// Reconstructs user-level run inputs from a container's resolved init process,
    /// by comparing against the image's entrypoint/cmd/env.
    static func recreatePrefill(for record: ContainerRecord) async -> RecreatePrefill {
        var prefill = RecreatePrefill()
        let full = [record.configuration.initProcess?.executable].compactMap { $0 }
            + (record.configuration.initProcess?.arguments ?? [])
        let recordEnv = record.configuration.initProcess?.environment ?? []

        guard let reference = record.configuration.image?.reference,
              let config = try? await Backend.systemConfig(),
              let image = try? await ClientImage.get(reference: reference, containerSystemConfig: config),
              let platform = record.configuration.platform,
              let ociImage = try? await image.config(for: ContainerizationOCI.Platform(
                  arch: platform.architecture ?? "arm64", os: platform.os ?? "linux"))
        else {
            // Can't resolve the image config — fall back to the full command and env.
            prefill.commandArgs = full
            prefill.customEnv = recordEnv
            return prefill
        }

        let entrypoint = ociImage.config?.entrypoint ?? []
        let cmd = ociImage.config?.cmd ?? []
        if !entrypoint.isEmpty, full.count >= entrypoint.count, Array(full.prefix(entrypoint.count)) == entrypoint {
            let rest = Array(full.dropFirst(entrypoint.count))
            prefill.commandArgs = rest == cmd ? [] : rest
        } else {
            prefill.commandArgs = full == cmd ? [] : full
        }

        let imageEnv = Set(ociImage.config?.env ?? [])
        prefill.customEnv = recordEnv.filter { !imageEnv.contains($0) }
        return prefill
    }
}



enum VolumeBrowser {
    static let mountPoint = "/volume"
    static let helperImage = "docker.io/library/alpine:latest"

    /// Create + start a helper with the volume mounted at /volume; returns its id.
    static func open(volumeName: String) async throws -> String {
        do {
            let id = "davit-volume-\(volumeName)-\(UUID().uuidString.prefix(6))".lowercased()
            try await ContainerService.runContainer(
                image: helperImage,
                name: id,
                processArgs: [],
                managementArgs: [
                    "--mount", "type=volume,source=\(volumeName),target=\(mountPoint)",
                    "--label", "com.davit.volume-browser=\(volumeName)",
                ],
                resourceArgs: ["--cpus", "1", "--memory", "256m"],
                commandArgs: ["sleep", "86400"]
            )
            return id
        } catch let e as CLIError {
            throw e
        } catch {
            throw CLIError.wrap("browse volume \(volumeName)", error)
        }
    }

    static func close(_ helperID: String) async {
        try? await ContainerService.delete(helperID, force: true)
    }
}
