import ContainerAPIClient
import ContainerResource
import Foundation

// View models mapped from ContainerAPIClient / ContainerResource types.
// Kept as plain structs so views stay decoupled from the (unstable) library API.
// Ported from davit Models.swift; visibility changed to `public` (shared library).
// NOTE: davit's `ContainerState.color` (SwiftUI) lives in the app target instead —
// this library must not depend on SwiftUI.

// MARK: - Containers

public struct ContainerRecord: Identifiable, Hashable, Encodable {
    public let id: String
    public let status: ContainerStatus?
    public let configuration: ContainerConfigurationInfo

    public var state: ContainerState { ContainerState(rawValue: status?.state.lowercased() ?? "stopped") ?? .unknown }
    public var isRunning: Bool { state == .running }
    public var imageReference: String { configuration.image?.reference ?? "—" }
    public var shortImage: String { ImageRecord.shortName(imageReference) }
    public var primaryIPv4: String? {
        status?.networks?.first?.ipv4Address?.split(separator: "/").first.map(String.init)
    }
    public var command: String {
        let p = configuration.initProcess
        return (([p?.executable ?? ""] + (p?.arguments ?? [])).joined(separator: " ")).trimmingCharacters(in: .whitespaces)
    }
    public var created: Date? { parseISODate(configuration.creationDate) }
    public var started: Date? { parseISODate(status?.startedDate) }

    public init(id: String, status: ContainerStatus?, configuration: ContainerConfigurationInfo) {
        self.id = id
        self.status = status
        self.configuration = configuration
    }
}

public extension ContainerRecord {
    init(snapshot: ContainerSnapshot) {
        let cfg = snapshot.configuration
        self.id = snapshot.id
        self.status = ContainerStatus(
            state: snapshot.status.rawValue,
            startedDate: snapshot.startedDate.map(isoString),
            networks: snapshot.networks.map { attachment in
                ContainerNetworkStatus(
                    network: attachment.network,
                    hostname: attachment.hostname,
                    ipv4Address: String(describing: attachment.ipv4Address),
                    ipv4Gateway: String(describing: attachment.ipv4Gateway),
                    ipv6Address: attachment.ipv6Address.map { String(describing: $0) },
                    macAddress: attachment.macAddress.map { String(describing: $0) },
                    mtu: attachment.mtu.map(Int.init)
                )
            }
        )
        self.configuration = ContainerConfigurationInfo(
            id: cfg.id,
            creationDate: isoString(cfg.creationDate),
            image: ImageReferenceInfo(reference: cfg.image.reference, digest: cfg.image.digest),
            initProcess: InitProcessInfo(
                executable: cfg.initProcess.executable,
                arguments: cfg.initProcess.arguments,
                environment: cfg.initProcess.environment,
                workingDirectory: cfg.initProcess.workingDirectory,
                terminal: cfg.initProcess.terminal
            ),
            labels: cfg.labels,
            mounts: cfg.mounts.map(MountRecord.init(filesystem:)),
            platform: PlatformRecord(architecture: cfg.platform.architecture, os: cfg.platform.os),
            publishedPorts: cfg.publishedPorts.map { port in
                PublishedPort(
                    containerPort: Int(port.containerPort),
                    hostPort: Int(port.hostPort),
                    hostAddress: String(describing: port.hostAddress),
                    proto: port.proto.rawValue
                )
            },
            resources: ResourceLimits(cpus: cfg.resources.cpus, memoryInBytes: Int64(cfg.resources.memoryInBytes)),
            rosetta: cfg.rosetta,
            readOnly: cfg.readOnly,
            runtimeHandler: cfg.runtimeHandler
        )
    }
}

public enum ContainerState: String {
    case running, stopped, stopping, unknown

    /// The SwiftUI `Color` mapping lives in the app target (extension) — this
    /// library stays SwiftUI-free.
    public var label: String { rawValue.capitalized }
}

public struct ContainerStatus: Hashable, Encodable {
    public let state: String
    public let startedDate: String?
    public let networks: [ContainerNetworkStatus]?

    public init(state: String, startedDate: String?, networks: [ContainerNetworkStatus]?) {
        self.state = state
        self.startedDate = startedDate
        self.networks = networks
    }
}

public struct ContainerNetworkStatus: Hashable, Encodable {
    public let network: String?
    public let hostname: String?
    public let ipv4Address: String?
    public let ipv4Gateway: String?
    public let ipv6Address: String?
    public let macAddress: String?
    public let mtu: Int?

    public init(network: String?, hostname: String?, ipv4Address: String?, ipv4Gateway: String?, ipv6Address: String?, macAddress: String?, mtu: Int?) {
        self.network = network
        self.hostname = hostname
        self.ipv4Address = ipv4Address
        self.ipv4Gateway = ipv4Gateway
        self.ipv6Address = ipv6Address
        self.macAddress = macAddress
        self.mtu = mtu
    }
}

public struct ContainerConfigurationInfo: Hashable, Encodable {
    public let id: String?
    public let creationDate: String?
    public let image: ImageReferenceInfo?
    public let initProcess: InitProcessInfo?
    public let labels: [String: String]?
    public let mounts: [MountRecord]?
    public let platform: PlatformRecord?
    public let publishedPorts: [PublishedPort]?
    public let resources: ResourceLimits?
    public let rosetta: Bool?
    public let readOnly: Bool?
    public let runtimeHandler: String?

    public init(id: String?, creationDate: String?, image: ImageReferenceInfo?, initProcess: InitProcessInfo?, labels: [String: String]?, mounts: [MountRecord]?, platform: PlatformRecord?, publishedPorts: [PublishedPort]?, resources: ResourceLimits?, rosetta: Bool?, readOnly: Bool?, runtimeHandler: String?) {
        self.id = id
        self.creationDate = creationDate
        self.image = image
        self.initProcess = initProcess
        self.labels = labels
        self.mounts = mounts
        self.platform = platform
        self.publishedPorts = publishedPorts
        self.resources = resources
        self.rosetta = rosetta
        self.readOnly = readOnly
        self.runtimeHandler = runtimeHandler
    }
}

public struct ImageReferenceInfo: Hashable, Encodable {
    public let reference: String?
    public let digest: String?

    public init(reference: String?, digest: String?) {
        self.reference = reference
        self.digest = digest
    }
}

public struct InitProcessInfo: Hashable, Encodable {
    public let executable: String?
    public let arguments: [String]?
    public let environment: [String]?
    public let workingDirectory: String?
    public let terminal: Bool?

    public init(executable: String?, arguments: [String]?, environment: [String]?, workingDirectory: String?, terminal: Bool?) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.terminal = terminal
    }
}

public struct MountRecord: Hashable, Encodable {
    public let destination: String?
    public let source: String?
    public let kind: String
    public let volumeName: String?

    public init(filesystem fs: Filesystem) {
        self.destination = fs.destination
        self.source = fs.source
        // enum case label, e.g. "block(format: ...)" → "block", "virtiofs" → "virtiofs"
        let label = String(describing: fs.type)
        let caseName = label.split(separator: "(").first.map(String.init) ?? "mount"
        self.volumeName = VolumeRecord.volumeName(fromSource: fs.source)
        switch caseName {
        case "virtiofs": self.kind = "bind"
        case "block": self.kind = self.volumeName != nil ? "volume" : "block"
        default: self.kind = caseName
        }
    }

    public var kindLabel: String { kind }
    public var displaySource: String { volumeName ?? source ?? "—" }
}

public struct PlatformRecord: Hashable, Encodable {
    public let architecture: String?
    public let os: String?
    public var display: String { "\(os ?? "?")/\(architecture ?? "?")" }

    public init(architecture: String?, os: String?) {
        self.architecture = architecture
        self.os = os
    }
}

public struct PublishedPort: Hashable, Encodable {
    public let containerPort: Int?
    public let hostPort: Int?
    public let hostAddress: String?
    public let proto: String?

    public var display: String {
        "\(hostAddress ?? "0.0.0.0"):\(hostPort ?? 0) → \(containerPort ?? 0)/\(proto ?? "tcp")"
    }
    public var shortDisplay: String { "\(hostPort ?? 0):\(containerPort ?? 0)" }

    public init(containerPort: Int?, hostPort: Int?, hostAddress: String?, proto: String?) {
        self.containerPort = containerPort
        self.hostPort = hostPort
        self.hostAddress = hostAddress
        self.proto = proto
    }
}

public struct ResourceLimits: Hashable, Encodable {
    public let cpus: Int?
    public let memoryInBytes: Int64?

    public init(cpus: Int?, memoryInBytes: Int64?) {
        self.cpus = cpus
        self.memoryInBytes = memoryInBytes
    }
}

// MARK: - Images

public struct ImageRecord: Identifiable, Hashable, Encodable {
    public struct Variant: Hashable, Encodable {
        public let display: String
        public let size: Int64

        public init(display: String, size: Int64) {
            self.display = display
            self.size = size
        }
    }

    public let id: String
    public let name: String
    public let digest: String?
    public let totalSize: Int64
    public let platforms: [String]
    public let variants: [Variant]

    public var shortNameTag: String { Self.shortName(name) }
    public var created: Date? { nil }  // creation date is not exposed by the image store API

    /// "docker.io/library/alpine:latest" → "alpine:latest"
    public static func shortName(_ ref: String) -> String {
        var s = ref
        for prefix in ["docker.io/library/", "docker.io/"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        return s
    }

    public func matchesReference(_ ref: String) -> Bool {
        !Self.referenceAliases(for: name).isDisjoint(with: Self.referenceAliases(for: ref))
    }

    private static func referenceAliases(for ref: String) -> Set<String> {
        let ref = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { return [] }

        var aliases: Set<String> = []
        func add(_ value: String) {
            guard !value.isEmpty else { return }
            aliases.insert(value)
            aliases.insert(withImplicitLatestTag(value))
        }

        add(ref)

        let short = shortName(ref)
        add(short)

        if short.hasPrefix("library/") {
            add(String(short.dropFirst("library/".count)))
        }

        return aliases
    }

    private static func withImplicitLatestTag(_ ref: String) -> String {
        guard !ref.contains("@") else { return ref }
        let lastSlash = ref.lastIndex(of: "/")
        if let lastColon = ref.lastIndex(of: ":"), lastSlash == nil || lastColon > lastSlash! {
            return ref
        }
        return "\(ref):latest"
    }

    public var repository: String {
        let base = shortNameTag.split(separator: ":").dropLast().joined(separator: ":")
        return base.isEmpty ? shortNameTag : base
    }
    public var tag: String {
        let parts = shortNameTag.split(separator: ":")
        return parts.count > 1 ? String(parts.last!) : "latest"
    }

    public init(id: String, name: String, digest: String?, totalSize: Int64, platforms: [String], variants: [Variant]) {
        self.id = id
        self.name = name
        self.digest = digest
        self.totalSize = totalSize
        self.platforms = platforms
        self.variants = variants
    }
}

public extension ImageRecord {
    init(client image: ClientImage) async {
        let index = try? await image.index()
        var variants: [Variant] = []
        for manifest in index?.manifests ?? [] {
            guard let platform = manifest.platform, platform.os != "unknown" else { continue }
            variants.append(Variant(display: "\(platform.os)/\(platform.architecture)", size: manifest.size))
        }
        var seen = Set<String>()
        let platforms = variants.map(\.display).filter { seen.insert($0).inserted }
        let totalSize = (try? await ClientImage.getFullImageSize(image: image)) ?? 0
        self.init(
            id: image.digest,
            name: image.reference,
            digest: image.digest,
            totalSize: totalSize,
            platforms: platforms,
            variants: variants
        )
    }
}

public extension ImageRecord {
    enum Compatibility: Hashable {
        case unknown
        case native
        case amd64RequiresRosetta
        case otherCrossArch
    }

    func compatibility(hostArch: String) -> Compatibility {
        guard !variants.isEmpty else { return .unknown }
        let nativeDisplay = "linux/\(hostArch)"
        if platforms.contains(nativeDisplay) { return .native }
        if hostArch == "arm64" && platforms.contains("linux/amd64") {
            return .amd64RequiresRosetta
        }
        return .otherCrossArch
    }
}

// MARK: - Networks

public struct NetworkRecord: Identifiable, Hashable, Encodable {
    public let id: String
    public let name: String
    public let isBuiltin: Bool
    public let createdISO: String?
    public let subnet: String?
    public let mode: String?

    public var created: Date? { parseISODate(createdISO) }

    public init(resource: NetworkResource) {
        self.id = resource.id
        self.name = resource.name
        self.isBuiltin = resource.isBuiltin
        self.createdISO = isoString(resource.creationDate)
        self.subnet = resource.configuration.ipv4Subnet.map { String(describing: $0) }
        self.mode = String(describing: resource.configuration.mode)
    }
}

// MARK: - Volumes

public struct VolumeRecord: Identifiable, Hashable, Encodable {
    public let id: String
    public let name: String
    public let createdISO: String?
    public let format: String?
    public let source: String?
    public let sizeInBytes: Int64?

    public var created: Date? { parseISODate(createdISO) }

    public init(configuration: VolumeConfiguration) {
        self.id = configuration.name
        self.name = configuration.name
        self.createdISO = isoString(configuration.creationDate)
        self.format = configuration.format
        self.source = configuration.source
        self.sizeInBytes = nil
    }

    /// Volumes are backed by "<appRoot>/volumes/<name>/volume.img"; extract <name>.
    public static func volumeName(fromSource source: String?) -> String? {
        guard let source else { return nil }
        let parts = source.split(separator: "/").map(String.init)
        guard let i = parts.lastIndex(of: "volumes"), i + 1 < parts.count,
              parts.last?.hasSuffix(".img") == true else { return nil }
        return parts[i + 1]
    }
}

// MARK: - Stats

public struct StatsRecord: Identifiable, Hashable {
    public let id: String
    public let cpuUsageUsec: Int64?
    public let memoryUsageBytes: Int64?
    public let memoryLimitBytes: Int64?
    public let networkRxBytes: Int64?
    public let networkTxBytes: Int64?
    public let blockReadBytes: Int64?
    public let blockWriteBytes: Int64?
    public let numProcesses: Int?

    public init(stats: ContainerStats) {
        self.id = stats.id
        self.cpuUsageUsec = stats.cpuUsageUsec.map(Int64.init)
        self.memoryUsageBytes = stats.memoryUsageBytes.map(Int64.init)
        self.memoryLimitBytes = stats.memoryLimitBytes.map(Int64.init)
        self.networkRxBytes = stats.networkRxBytes.map(Int64.init)
        self.networkTxBytes = stats.networkTxBytes.map(Int64.init)
        self.blockReadBytes = stats.blockReadBytes.map(Int64.init)
        self.blockWriteBytes = stats.blockWriteBytes.map(Int64.init)
        self.numProcesses = stats.numProcesses.map(Int.init)
    }
}

/// A processed stats sample with derived CPU percentage.
public struct StatsSample: Identifiable, Hashable {
    public let id = UUID()
    public let time: Date
    public let cpuPercent: Double
    public let memoryBytes: Int64
    public let memoryLimit: Int64
    public let rxBytes: Int64
    public let txBytes: Int64
    /// Disk I/O throughput in bytes/second, derived from block-I/O deltas.
    public let diskReadRate: Double
    public let diskWriteRate: Double
    /// Disk space consumed by the container (writable layer). Refreshed on a
    /// slower cadence than the 2s stats poll and carried forward between refreshes.
    public let diskUsageBytes: Int64
    public let processes: Int

    public var memoryPercent: Double {
        memoryLimit > 0 ? Double(memoryBytes) / Double(memoryLimit) * 100 : 0
    }

    public init(time: Date, cpuPercent: Double, memoryBytes: Int64, memoryLimit: Int64, rxBytes: Int64, txBytes: Int64, diskReadRate: Double, diskWriteRate: Double, diskUsageBytes: Int64, processes: Int) {
        self.time = time
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.memoryLimit = memoryLimit
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.diskReadRate = diskReadRate
        self.diskWriteRate = diskWriteRate
        self.diskUsageBytes = diskUsageBytes
        self.processes = processes
    }
}

// MARK: - Machines

/// A container machine (micro VM) as shown in the UI.
public struct MachineRecord: Identifiable, Hashable {
    public let id: String
    public let statusRaw: String
    public let imageReference: String
    public let ipAddress: String?
    public let cpus: Int
    public let memoryBytes: UInt64
    public let diskSize: UInt64?
    public let createdISO: String?
    public let startedISO: String?
    public let platform: String
    public let homeMount: String
    public let containerId: String?
    public var isDefault: Bool

    public var isRunning: Bool { statusRaw == "running" }
    public var created: Date? { parseISODate(createdISO) }
    public var dnsName: String { "\(id.lowercased()).machine" }

    public init(id: String, statusRaw: String, imageReference: String, ipAddress: String?, cpus: Int, memoryBytes: UInt64, diskSize: UInt64?, createdISO: String?, startedISO: String?, platform: String, homeMount: String, containerId: String?, isDefault: Bool) {
        self.id = id
        self.statusRaw = statusRaw
        self.imageReference = imageReference
        self.ipAddress = ipAddress
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.diskSize = diskSize
        self.createdISO = createdISO
        self.startedISO = startedISO
        self.platform = platform
        self.homeMount = homeMount
        self.containerId = containerId
        self.isDefault = isDefault
    }
}

// MARK: - Registries

/// A saved registry login (credentials live in the login keychain, not here).
public struct RegistryLoginRecord: Identifiable, Hashable {
    public let hostname: String
    public let username: String
    public let modified: Date?
    public var id: String { hostname }

    public init(hostname: String, username: String, modified: Date?) {
        self.hostname = hostname
        self.username = username
        self.modified = modified
    }
}

// MARK: - System

public struct DiskUsage: Hashable {
    public struct Section: Hashable {
        public let total: Int?
        public let active: Int?
        public let sizeInBytes: Int64?
        public let reclaimable: Int64?

        public init(total: Int?, active: Int?, sizeInBytes: Int64?, reclaimable: Int64?) {
            self.total = total
            self.active = active
            self.sizeInBytes = sizeInBytes
            self.reclaimable = reclaimable
        }
    }
    public let containers: Section?
    public let images: Section?
    public let volumes: Section?

    public init(containers: Section?, images: Section?, volumes: Section?) {
        self.containers = containers
        self.images = images
        self.volumes = volumes
    }
}

public enum SystemState: Equatable {
    case running(version: String?)
    case stopped
    case unknown

    public var isRunning: Bool { if case .running = self { return true }; return false }
}

// MARK: - Helpers

private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

public func parseISODate(_ s: String?) -> Date? {
    guard let s else { return nil }
    return isoPlain.date(from: s) ?? isoFractional.date(from: s)
}

public func isoString(_ date: Date) -> String {
    isoPlain.string(from: date)
}

public func formatBytes(_ bytes: Int64?) -> String {
    guard let bytes, bytes > 0 else { return "0 B" }
    let fmt = ByteCountFormatter()
    fmt.countStyle = .file
    return fmt.string(fromByteCount: bytes)
}

public func relativeDate(_ date: Date?) -> String {
    guard let date else { return "—" }
    let fmt = RelativeDateTimeFormatter()
    fmt.unitsStyle = .abbreviated
    return fmt.localizedString(for: date, relativeTo: Date())
}
