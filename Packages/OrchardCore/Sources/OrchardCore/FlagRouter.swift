import Foundation

/// Pure docker-flag router, extracted from davit's `RunCLI` (Main.swift) so the
/// CLI (`orchard run`) and the GUI Run sheet share one grammar and it is
/// unit-testable without spawning processes.
///
/// Recognized flags route into the same four arg arrays Apple's
/// `Flags.Process/Management/Resource` parsers consume — this layer only
/// decides which bucket a token belongs to and whether it consumes a value.
/// Everything after IMAGE is the command argv, never parsed.
public enum FlagRouter {
    public enum Bucket { case process, management, resource }

    /// flag token → (bucket, takesValue). Both spellings route to the same
    /// bucket; the RAW token (not a canonical name) is what gets appended,
    /// since the platform parsers read the real docker spelling themselves.
    public static let routing: [String: (bucket: Bucket, takesValue: Bool)] = [
        // process
        "-e": (.process, true), "--env": (.process, true),
        "--env-file": (.process, true),
        "-t": (.process, false), "--tty": (.process, false),
        "-u": (.process, true), "--user": (.process, true),
        "--uid": (.process, true), "--gid": (.process, true),
        "-w": (.process, true), "--workdir": (.process, true),
        "--ulimit": (.process, true),
        // resource
        "-c": (.resource, true), "--cpus": (.resource, true),
        "-m": (.resource, true), "--memory": (.resource, true),
        // management
        "-p": (.management, true), "--publish": (.management, true),
        "-v": (.management, true), "--volume": (.management, true),
        "--mount": (.management, true),
        "--tmpfs": (.management, true),
        "--network": (.management, true),
        "--entrypoint": (.management, true),
        "-l": (.management, true), "--label": (.management, true),
        "--platform": (.management, true),
        "--arch": (.management, true),
        "--os": (.management, true),
        "--cap-add": (.management, true),
        "--cap-drop": (.management, true),
        "--init": (.management, false),
        "--read-only": (.management, false),
        "--shm-size": (.management, true),
        "--dns": (.management, true),
        "--dns-search": (.management, true),
        "--dns-option": (.management, true),
        "--no-dns": (.management, false),
        "--rosetta": (.management, false),
        "--virtualization": (.management, false),
        "--ssh": (.management, false),
    ]

    /// Real docker run flags this platform has no equivalent for. Naming them
    /// explicitly gives a docker-parity script an actionable message instead
    /// of a bare syntax error, so it fails loudly instead of silently losing
    /// the setting (davit's fail-loudly philosophy).
    public static let unsupported: Set<String> = [
        "--restart", "--add-host", "--privileged", "--hostname", "-h", "--domainname",
        "--mac-address", "--gpus", "--device", "--device-cgroup-rule", "--link",
        "--pid", "--ipc", "--uts", "--userns", "--security-opt", "--sysctl",
        "--group-add", "--isolation", "--cgroup-parent", "--volumes-from",
        "--stop-signal", "--stop-timeout", "--expose", "-P", "--publish-all",
        "--log-driver", "--log-opt", "-a", "--attach",
        "--health-cmd", "--health-interval", "--health-retries", "--health-timeout",
        "--health-start-period", "--no-healthcheck",
        "--memory-swap", "--memory-reservation", "--memory-swappiness", "--kernel-memory",
        "--cpu-shares", "--cpuset-cpus", "--cpuset-mems", "--cpu-quota", "--cpu-period",
        "--cpu-rt-runtime", "--cpu-rt-period", "--oom-kill-disable", "--oom-score-adj",
        "--pids-limit", "--blkio-weight", "--blkio-weight-device",
        "--device-read-bps", "--device-write-bps", "--device-read-iops", "--device-write-iops",
    ]

    public struct Invocation {
        public var image = ""
        public var command: [String] = []
        public var process: [String] = []
        public var management: [String] = []
        public var resource: [String] = []
        public var name: String? = nil
        public var cidfile: String? = nil
        public var detach = false
        public var autoRemove = false
        public var pullPolicy = "missing"
        public var verbose = false
        public var quiet = false

        public init() {}
    }

    /// Thrown instead of exiting the process — keeps the routing logic
    /// testable. `message == nil` prints the bare usage line only.
    public struct ParseError: Error, Equatable {
        public let message: String?
        public var isHelp: Bool = false

        public init(message: String?, isHelp: Bool = false) {
            self.message = message
            self.isHelp = isHelp
        }
    }

    /// Pure routing core: no I/O, no `exit()`. The process-exiting shell that
    /// the CLI wraps this in lives in orchard-cli.
    public static func parse(_ args: [String]) throws -> Invocation {
        var args = args
        var inv = Invocation()
        var i = 0
        while i < args.count {
            let raw = args[i]
            if raw == "--" {
                i += 1
                break
            }
            var arg = raw
            var inline: String? = nil
            if raw.hasPrefix("--"), let eq = raw.firstIndex(of: "=") {
                arg = String(raw[..<eq])
                inline = String(raw[raw.index(after: eq)...])
            }
            func value() throws -> String {
                if let v = inline { return v }
                guard i + 1 < args.count else { throw ParseError(message: "flag \(arg) needs a value") }
                i += 1
                return args[i]
            }
            if arg == "-d" || arg == "--detach" {
                guard inline == nil else { throw ParseError(message: "flag \(arg) takes no value") }
                inv.detach = true
            } else if arg == "--rm" {
                guard inline == nil else { throw ParseError(message: "flag \(arg) takes no value") }
                inv.autoRemove = true
            } else if arg == "--pull" {
                let v = try value()
                guard ["missing", "always", "never"].contains(v) else {
                    throw ParseError(message: "invalid --pull value: \(v) (want missing|always|never)")
                }
                inv.pullPolicy = v
            } else if arg == "-i" || arg == "--interactive" {
                throw ParseError(message: "interactive runs aren't supported; start detached, then `orchard exec <name>`")
            } else if arg == "--name" {
                let v = try value()
                inv.name = v
                inv.management.append(contentsOf: [arg, v])
            } else if arg == "--cidfile" {
                // Intercepted rather than routed — the create path never reads
                // Flags.Management.cidfile; the CLI writes the file itself.
                inv.cidfile = try value()
            } else if arg == "--verbose" {
                guard inline == nil else { throw ParseError(message: "flag \(arg) takes no value") }
                inv.verbose = true
            } else if arg == "-q" || arg == "--quiet" {
                guard inline == nil else { throw ParseError(message: "flag \(arg) takes no value") }
                inv.quiet = true
            } else if arg == "--help" {
                guard inline == nil else { throw ParseError(message: "flag \(arg) takes no value") }
                throw ParseError(message: nil, isHelp: true)
            } else if unsupported.contains(arg) {
                let hint = arg == "-h" ? "; for help, use --help" : ""
                throw ParseError(message: "docker flag \(arg) has no equivalent on this platform (apple/container doesn't support it) — remove it or adjust the parity script\(hint)")
            } else if let route = routing[arg] {
                if route.takesValue {
                    let v = try value()
                    switch route.bucket {
                    case .process: inv.process.append(contentsOf: [arg, v])
                    case .management: inv.management.append(contentsOf: [arg, v])
                    case .resource: inv.resource.append(contentsOf: [arg, v])
                    }
                } else {
                    guard inline == nil else { throw ParseError(message: "flag \(arg) takes no value") }
                    switch route.bucket {
                    case .process: inv.process.append(arg)
                    case .management: inv.management.append(arg)
                    case .resource: inv.resource.append(arg)
                    }
                }
            } else if raw.hasPrefix("-"), !raw.hasPrefix("--"), raw.count > 2,
                      raw.dropFirst().allSatisfy({ "dtiq".contains($0) }) {
                // Docker's clustered short flags (`-it`, `-dit`, ...) — expand
                // into individual tokens and splice them back so each one
                // re-dispatches. Any letter outside {d,t,i,q} falls through to
                // the plain unknown-flag error below.
                args.replaceSubrange(i...i, with: raw.dropFirst().map { "-\($0)" })
                continue
            } else if raw.hasPrefix("-"), raw != "-" {
                throw ParseError(message: "unknown flag: \(raw)")
            } else {
                inv.image = raw
                i += 1
                break
            }
            i += 1
        }
        if inv.image.isEmpty {
            guard i < args.count else { throw ParseError(message: nil) }
            inv.image = args[i]
            i += 1
        }
        inv.command = i < args.count ? Array(args[i...]) : []
        if inv.verbose, inv.quiet {
            throw ParseError(message: "--verbose and -q/--quiet are mutually exclusive")
        }
        return inv
    }
}
