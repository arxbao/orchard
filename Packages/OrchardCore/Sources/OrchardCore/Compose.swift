import Foundation
import Yams

/// Docker Compose import: parse a compose file into a concrete creation plan —
/// named volumes and networks to create, then services as the same four flag
/// arrays the Run sheet feeds `Backend.runContainer`. apple/container has no
/// native compose, so this is pure app-side orchestration. The supported subset
/// is deliberate; everything else surfaces as a warning, never silently.
public enum Compose {
    /// Ownership label stamped on every container this compose path creates.
    /// Identity by name alone is not enough: without this, `up` would delete
    /// or adopt a user's unrelated container that happens to share a name.
    static let projectLabel = "com.davit.compose.project"


    public struct ServicePlan: Identifiable, Hashable {
        public let service: String          // compose service key
        public let name: String             // container name (container_name or <project>-<service>)
        public let image: String
        public var processArgs: [String]
        public var managementArgs: [String]
        public var resourceArgs: [String]
        public var commandArgs: [String]
        public var profiles: [String]       // empty = always enabled
        public var healthcheck: Healthcheck?
        public var dependsOn: [String: DependsCondition]
        public var stopGracePeriod: Double? // seconds; nil = platform stop default
        public var stopSignal: String?      // signal name or number — the daemon parses it
        public var build: BuildSpec?        // when set, `up` builds this image first
        public var id: String { service }

        /// Equivalent `container run …` (what Davit performs over XPC).
        public var cliPreview: String {
            var argv = ["container", "run", "--detach", "--name", name]
            argv += managementArgs + resourceArgs + processArgs
            argv.append(image)
            argv += commandArgs
            return argv.map(Compose.shellQuote).joined(separator: " ")
        }

        /// Paired `--network` values — the networks this service attaches to.
        public var networkRefs: [String] { paired("--network") }

        /// Named-volume sources of `--mount type=volume,…` specs.
        public var volumeRefs: [String] {
            paired("--mount").compactMap { spec in
                guard spec.hasPrefix("type=volume,") else { return nil }
                return spec.split(separator: ",").first { $0.hasPrefix("source=") }
                    .map { String($0.dropFirst("source=".count)) }
            }
        }

        private func paired(_ flag: String) -> [String] {
            managementArgs.indices.compactMap { i in
                managementArgs[i] == flag && i + 1 < managementArgs.count ? managementArgs[i + 1] : nil
            }
        }
    }

    /// A compose `build:` block resolved to absolute paths + the tag to build.
    public struct BuildSpec: Hashable {
        public var context: String        // absolute
        public var dockerfile: String     // absolute
        public var tag: String            // image ref to produce
        public var args: [String]         // KEY=value
    }

    public struct Plan: Identifiable {
        public var id: String { project }
        public let project: String
        public var volumes: [String]        // named volumes to create (missing ones only — caller filters)
        public var networks: [String]       // networks to create
        public var externalVolumes: Set<String>   // declared `external:` — down leaves them alone
        public var externalNetworks: Set<String>
        public var services: [ServicePlan]  // in dependency start order
        public var allServices: [ServicePlan]  // every service in the file, regardless of selection/profiles — hosts sync must cover unselected running containers too
        public var warnings: [String]
    }

    /// Parsed healthcheck with docker defaults applied at parse time.
    public struct Healthcheck: Hashable {
        public let test: [String]           // probe command without the CMD/CMD-SHELL head
        public let shellForm: Bool          // string or CMD-SHELL test — runs via /bin/sh -c
        public let interval: Double         // seconds (docker default 30)
        public let timeout: Double          // seconds (docker default 30)
        public let retries: Int             // consecutive failures until unhealthy (default 3)
        public let startPeriod: Double      // seconds; failures inside don't count (default 0)

        /// Concrete probe argv for `ContainerService.exec`.
        public var argv: [String] { shellForm ? ["/bin/sh", "-c", test.joined(separator: " ")] : test }
    }

    public enum DependsCondition: String, Hashable {
        case started = "service_started"
        case healthy = "service_healthy"
        case completedSuccessfully = "service_completed_successfully"
    }

    public enum Error: Swift.Error, LocalizedError {
        case notAMapping
        case noServices
        case invalidServiceName(String)
        case missingImage(service: String)
        case dependencyCycle([String])
        case unknownDependency(service: String, dependsOn: String)
        case missingHealthcheck(service: String, dependency: String)
        case noSuchService(String)
        case serviceNotRunning(String)
        case inactiveProfile(service: String, profile: String)
        case envFileNotFound(String)
        case requiredVariable(name: String, message: String)
        case unhealthy(service: String, failures: Int)
        case dependencyExited(service: String)
        case didNotComplete(service: String, exitCode: Int32?)
        case foreignContainer(name: String)

        public var errorDescription: String? {
            switch self {
            case .notAMapping: return "not a compose file (top level is not a mapping)"
            case .noServices: return "no services defined"
            case .invalidServiceName(let s):
                return "service name \(s.debugDescription) is invalid — only [a-zA-Z0-9._-] is allowed"
            case .missingImage(let s): return "service \"\(s)\" has neither image: nor build:"
            case .foreignContainer(let n):
                return "container \"\(n)\" exists but was not created by this compose project (missing \(Compose.projectLabel) label) — delete or rename it, then run up again"
            case .dependencyCycle(let names): return "depends_on cycle: \(names.joined(separator: " → "))"
            case .unknownDependency(let s, let d): return "service \"\(s)\" depends on unknown service \"\(d)\""
            case .missingHealthcheck(let s, let d): return "service \"\(s)\" needs \"\(d)\" healthy, but \"\(d)\" has no healthcheck"
            case .noSuchService(let s): return "no such service: \(s)"
            case .serviceNotRunning(let s): return "service \"\(s)\" has no running container"
            case .inactiveProfile(let s, let p): return "service \"\(s)\" requires profile \"\(p)\" — activate it with --profile \(p)"
            case .envFileNotFound(let p): return "env file not found: \(p)"
            case .requiredVariable(let name, let message):
                return "required variable \"\(name)\" is not set" + (message.isEmpty ? "" : ": \(message)")
            case .unhealthy(let s, let n): return "service \"\(s)\" is unhealthy after \(n) failed probes"
            case .dependencyExited(let s): return "service \"\(s)\" exited before becoming healthy"
            case .didNotComplete(let s, let code):
                return code.map { "service \"\(s)\" didn't complete successfully: exit \($0)" }
                    ?? "service \"\(s)\" wasn't started by this compose up, so its exit code is unknown"
            }
        }
    }

    // MARK: discovery

    /// Docker-style compose file autodiscovery. `COMPOSE_FILE` (single path,
    /// absolute or relative to `dir`) wins and is trusted as-is — a bad path
    /// surfaces when the file is read. Otherwise each directory from `dir` up
    /// to / is tried for the candidate names in docker's order; when both
    /// compose.yaml and compose.yml exist in the winning directory,
    /// compose.yaml wins with a warning (docker parity).
    public static func discoverFile(
        startingAt dir: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (path: String, warning: String?)? {
        if let override = environment["COMPOSE_FILE"], !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            let path = expanded.hasPrefix("/")
                ? expanded
                : URL(fileURLWithPath: dir).appendingPathComponent(expanded).standardizedFileURL.path
            return (path, nil)
        }
        let candidates = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"]
        var url = URL(fileURLWithPath: dir).standardizedFileURL
        while true {
            let present = candidates.filter { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
            if let winner = present.first {
                let warning = present.contains("compose.yaml") && present.contains("compose.yml")
                    ? "both compose.yaml and compose.yml exist in \(url.path) — using compose.yaml"
                    : nil
                return (url.appendingPathComponent(winner).path, warning)
            }
            if url.path == "/" { return nil }
            url.deleteLastPathComponent()
        }
    }

    // MARK: environment + interpolation

    /// KEY=VALUE dotenv subset: whitespace trimmed, blank and #-comment lines
    /// skipped, optional `export ` prefix, one matching pair of single or
    /// double quotes stripped from the value — no escape processing beyond
    /// that. Docker parity (load-time interpolation): a single-quoted value
    /// stays literal; every other value is run through the existing
    /// `substitute` grammar immediately, left-to-right, against `lookup =
    /// processEnvironment (wins) ∪ this file's own previously-defined
    /// entries` — so a later line can reference an earlier one, but the
    /// caller's environment always wins a naming conflict. `${X:?msg}` throws
    /// like it does during YAML substitution; other warnings (e.g. an unset
    /// variable) are returned rather than printed, so the caller can route
    /// them into whatever warnings channel it has.
    private static func parseDotEnv(
        text: String, processEnvironment: [String: String], fallback: [String: String] = [:]
    ) throws -> (values: [String: String], warnings: [String]) {
        var out: [String: String] = [:]
        var warnings: [String] = []
        var warned = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            // .whitespacesAndNewlines: CRLF files otherwise leave a trailing
            // \r in every value and defeat the quote stripping below.
            var entry = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if entry.isEmpty || entry.hasPrefix("#") { continue }
            if entry.hasPrefix("export ") { entry = String(entry.dropFirst("export ".count)) }
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = entry[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = entry[entry.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            var singleQuoted = false
            // Docker dotenv: a quoted value ends at the MATCHING close quote
            // (anything after, e.g. an inline comment, is dropped), and an
            // unquoted value is cut at the first whitespace-preceded "#".
            // Suffix-testing the whole line instead would mis-handle
            // `PASS='p$wd' # login` and interpolate a "literal" value.
            if let quote = value.first, quote == "'" || quote == "\"" {
                let inner = value.dropFirst()
                if let close = inner.firstIndex(of: quote) {
                    singleQuoted = (quote == "'")
                    value = String(inner[..<close])
                }
            } else if let hash = value.firstIndex(of: "#"),
                      hash != value.startIndex,
                      value[value.index(before: hash)].isWhitespace {
                value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            if !singleQuoted {
                // Precedence (compose-go): process/effective env > this file's
                // earlier lines > earlier env_files (the fallback tier).
                let lookup = fallback
                    .merging(out) { _, own in own }
                    .merging(processEnvironment) { _, process in process }
                value = try substitute(value, environment: lookup, warned: &warned, warnings: &warnings)
            }
            out[key] = value
        }
        return (out, warnings)
    }

    /// The environment interpolation sees: `<composeDir>/.env` (or an explicit
    /// env file) layered under the process environment — process wins (docker
    /// precedence). A missing default `.env` is simply absent; a missing
    /// explicit file is an error. `.env` values are interpolated at load time
    /// (see `parseDotEnv`); any warnings from that pass are returned alongside
    /// the resolved environment so callers can surface them.
    public static func effectiveEnvironment(
        composeDir: String,
        envFile: String? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (environment: [String: String], warnings: [String]) {
        let path = envFile ?? URL(fileURLWithPath: composeDir).appendingPathComponent(".env").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            if envFile != nil { throw Error.envFileNotFound(path) }
            return (processEnvironment, [])
        }
        let (values, warnings) = try parseDotEnv(text: text, processEnvironment: processEnvironment)
        return (values.merging(processEnvironment) { _, process in process }, warnings)
    }

    /// Replaces `${VAR}` in every string VALUE of the loaded YAML tree (never
    /// mapping keys), so the per-key parsing only ever sees resolved values.
    private static func interpolate(
        _ node: Any, environment: [String: String], warned: inout Set<String>, warnings: inout [String]
    ) throws -> Any {
        switch node {
        case let s as String:
            return try substitute(s, environment: environment, warned: &warned, warnings: &warnings)
        case let map as [String: Any]:
            var out = map
            for (k, v) in map { out[k] = try interpolate(v, environment: environment, warned: &warned, warnings: &warnings) }
            return out
        case let list as [Any]:
            return try list.map { try interpolate($0, environment: environment, warned: &warned, warnings: &warnings) }
        default:
            return node
        }
    }

    /// Compose substitution grammar: `$VAR`, `${VAR}`, `${VAR:-def}`,
    /// `${VAR-def}`, `${VAR:?err}`, `${VAR?err}`, `$$` → literal `$`; the `:`
    /// variants treat set-but-empty as unset. Unset plain substitution → empty
    /// string plus one warning per variable. Single pass, single level — a
    /// default is taken literally, nested `${…}` inside it is not expanded.
    private static func substitute(
        _ s: String, environment: [String: String], warned: inout Set<String>, warnings: inout [String]
    ) throws -> String {
        guard s.contains("$") else { return s }
        func nameStart(_ c: Character) -> Bool { c == "_" || ("A"..."Z").contains(c) || ("a"..."z").contains(c) }
        func nameChar(_ c: Character) -> Bool { nameStart(c) || ("0"..."9").contains(c) }
        func lookup(_ name: String) -> String {
            if let value = environment[name] { return value }
            if warned.insert(name).inserted {
                warnings.append("variable \"\(name)\" is not set — substituting an empty string")
            }
            return ""
        }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "$", s.index(after: i) < s.endIndex else {
                out.append(s[i]); i = s.index(after: i); continue
            }
            let next = s.index(after: i)
            if s[next] == "$" {                                    // $$ → literal $
                out.append("$")
                i = s.index(after: next)
            } else if s[next] == "{" {
                // Depth-aware close scan: "${VAR:-${OTHER}}" must close at the
                // matching brace, not the first one, or set-case values grow a
                // stray "}" (nested defaults inside are still taken literally).
                var depth = 1
                var scan = s.index(after: next)
                var closeFound: String.Index?
                while scan < s.endIndex {
                    if s[scan] == "{" { depth += 1 }
                    if s[scan] == "}" {
                        depth -= 1
                        if depth == 0 { closeFound = scan; break }
                    }
                    scan = s.index(after: scan)
                }
                guard let close = closeFound else {
                    out += s[i...]                                 // unterminated ${… — literal
                    break
                }
                let body = s[s.index(after: next)..<close]
                var j = body.startIndex
                while j < body.endIndex, nameChar(body[j]) { j = body.index(after: j) }
                let name = String(body[..<j])
                let rest = body[j...]
                let emptyIsUnset = rest.hasPrefix(":")
                let op = emptyIsUnset ? rest.dropFirst() : rest
                let value = environment[name].flatMap { emptyIsUnset && $0.isEmpty ? nil : $0 }
                if name.isEmpty {
                    out += s[i...close]                            // "${}" and friends — literal
                } else if rest.isEmpty {                           // ${VAR}
                    out += lookup(name)
                } else if op.hasPrefix("-") {                      // ${VAR-def} / ${VAR:-def}
                    out += value ?? String(op.dropFirst())
                } else if op.hasPrefix("?") {                      // ${VAR?err} / ${VAR:?err}
                    guard let value else {
                        throw Error.requiredVariable(name: name, message: String(op.dropFirst()))
                    }
                    out += value
                } else if op.hasPrefix("+") {                      // ${VAR+alt} / ${VAR:+alt}
                    out += value != nil ? String(op.dropFirst()) : ""
                } else {
                    warnings.append("\"${\(body)}\" is not a supported substitution — left as-is")
                    out += s[i...close]
                }
                i = s.index(after: close)
            } else if nameStart(s[next]) {                         // bare $VAR
                var j = s.index(after: next)
                while j < s.endIndex, nameChar(s[j]) { j = s.index(after: j) }
                out += lookup(String(s[next..<j]))
                i = j
            } else {
                out.append("$")                                    // $ before a non-name char — literal
                i = next
            }
        }
        return out
    }

    // MARK: parse

    public static func parse(
        text: String, projectName: String, baseDir: String? = nil,
        environment: [String: String] = [:]
    ) throws -> Plan {
        guard let loaded = try Yams.load(yaml: text) as? [String: Any] else { throw Error.notAMapping }

        var warnings: [String] = []
        // Interpolate before any per-key parsing, so ports, volumes, durations
        // and commands below only ever see resolved values.
        var warnedUnset = Set<String>()
        guard let root = try interpolate(
            loaded, environment: environment, warned: &warnedUnset, warnings: &warnings) as? [String: Any]
        else { throw Error.notAMapping }
        guard let services = root["services"] as? [String: Any], !services.isEmpty else { throw Error.noServices }

        if root["version"] != nil { /* informational only in modern compose; ignore silently */ }
        for key in root.keys where !["services", "volumes", "networks", "version", "name"].contains(key) {
            warnings.append("top-level \"\(key)\" is ignored")
        }
        let project = (root["name"] as? String) ?? projectName
        // Same charset rule as service keys: the project name is written into
        // the managed /etc/hosts block and used in container names.
        guard project.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw Error.invalidServiceName(project)
        }

        // Top-level declarations; `external: true` marks a resource someone else
        // manages — down never deletes those (up still creates missing ones, a
        // pre-existing divergence from docker's must-preexist rule).
        func declared(_ key: String) -> (names: [String], external: Set<String>) {
            guard let map = root[key] as? [String: Any] else { return ([], []) }
            let external = map.compactMap { name, spec in
                ((spec as? [String: Any])?["external"] as? Bool) == true ? name : nil
            }
            return (Array(map.keys), Set(external))
        }
        let (topVolumes, externalVolumes) = declared("volumes")
        let (topNetworks, externalNetworks) = declared("networks")

        var plans: [String: ServicePlan] = [:]
        for (svcName, svcAny) in services {
            // Docker's service-name charset. Beyond parity this protects the
            // managed /etc/hosts block: names end up as line content there,
            // and whitespace (or a quoted-key newline) would break out of it.
            guard svcName.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
                throw Error.invalidServiceName(svcName)
            }
            guard let svc = svcAny as? [String: Any] else {
                warnings.append("service \"\(svcName)\" is not a mapping — skipped")
                continue
            }
            let (plan, svcWarnings) = try parseService(
                key: svcName, svc: svc, project: project, declaredNetworks: topNetworks,
                baseDir: baseDir, environment: environment)
            plans[svcName] = plan
            warnings += svcWarnings
        }
        guard !plans.isEmpty else { throw Error.noServices }

        // depends_on → start order (topological). Conditions are honored at up time.
        let ordered = try topoSort(
            services: plans.keys.sorted(),
            dependsOn: plans.mapValues { $0.dependsOn.keys.sorted() })

        // service_healthy requires the dependency to define a healthcheck (docker parity).
        for svcName in ordered {
            for (dep, condition) in (plans[svcName]?.dependsOn ?? [:]).sorted(by: { $0.key < $1.key })
            where condition == .healthy && plans[dep]?.healthcheck == nil {
                throw Error.missingHealthcheck(service: svcName, dependency: dep)
            }
        }

        let orderedPlans = ordered.compactMap { plans[$0] }
        return Plan(
            project: project,
            volumes: topVolumes.sorted(),
            networks: topNetworks.sorted(),
            externalVolumes: externalVolumes,
            externalNetworks: externalNetworks,
            services: orderedPlans,
            allServices: orderedPlans,
            warnings: warnings
        )
    }

    // MARK: service

    private static func parseService(
        key: String, svc: [String: Any], project: String, declaredNetworks: [String],
        baseDir: String?, environment: [String: String]
    ) throws -> (ServicePlan, warnings: [String]) {
        var warnings: [String] = []

        // image OR build (docker allows build-only; with both, image is the
        // tag the build produces).
        let explicitImage = (svc["image"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let buildSpec = try parseBuild(svc["build"], service: key, project: key,
                                       image: explicitImage, baseDir: baseDir, warnings: &warnings)
        guard let image = explicitImage ?? buildSpec?.tag else {
            throw Error.missingImage(service: key)
        }
        let name = (svc["container_name"] as? String) ?? "\(project)-\(key)"
        // container_name reaches the same /etc/hosts lines as service keys;
        // docker rejects these charsets too.
        guard name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw Error.invalidServiceName(name)
        }

        var process: [String] = []
        var management: [String] = []
        var resource: [String] = []

        // env_file: string, list, or {path, required} entries — paths resolve
        // against the compose file's directory; contents load through the
        // same dotenv parser as .env, so values are interpolated at load
        // time too (docker parity — single-quoted values stay literal), each
        // file's own lookup layering the effective environment under its own
        // previously-defined entries AND every earlier env_file's already-parsed
        // values (compose-go parity — a later file can reference an earlier
        // one's variables). Later files override earlier ones; environment:
        // below overrides them all. A missing file is an error unless the
        // entry says `required: false`.
        var envFileSpecs: [(path: String, required: Bool)] = []
        func envFileSpec(_ entry: Any) {
            if let m = entry as? [String: Any] {
                if let p = m["path"] as? String, !p.isEmpty {
                    envFileSpecs.append((p, (m["required"] as? Bool) ?? true))
                } else {
                    warnings.append("\(key): env_file entry without a path — ignored")
                }
            } else {
                let s = scalarString(entry)
                if s.isEmpty {
                    warnings.append("\(key): empty env_file entry — ignored")
                } else {
                    envFileSpecs.append((s, true))
                }
            }
        }
        switch svc["env_file"] {
        case nil: break
        case let list as [Any]: for entry in list { envFileSpec(entry) }
        case let other?: envFileSpec(other)  // string or {path, required}
        }
        var fileEnv: [String: String] = [:]
        for (path, required) in envFileSpecs {
            let expanded = (path as NSString).expandingTildeInPath
            let resolved = expanded.hasPrefix("/")
                ? expanded
                : URL(fileURLWithPath: baseDir ?? FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(expanded).standardizedFileURL.path
            guard let text = try? String(contentsOfFile: resolved, encoding: .utf8) else {
                if required { throw Error.envFileNotFound(resolved) }
                continue
            }
            // Lookup precedence (compose-go): effective environment, then this
            // file's own earlier lines, then earlier env_files — a file
            // redefining X then referencing it must see its own value, not an
            // earlier file's.
            let (values, fileWarnings) = try parseDotEnv(
                text: text, processEnvironment: environment, fallback: fileEnv)
            fileEnv.merge(values) { _, later in later }
            warnings += fileWarnings
        }

        // environment: map or list form; its keys beat env_file entries
        var explicitEnv: [String] = []
        var explicitKeys = Set<String>()
        switch svc["environment"] {
        case let map as [String: Any]:
            for (k, v) in map.sorted(by: { $0.key < $1.key }) {
                explicitEnv += ["--env", "\(k)=\(scalarString(v))"]
                explicitKeys.insert(k)
            }
        case let list as [Any]:
            // KEY=VALUE passes through; a bare KEY resolves from the effective
            // environment (docker parity), falls back to an env_file value, or
            // is omitted with a warning.
            for entry in list {
                let s = scalarString(entry)
                if let eq = s.firstIndex(of: "=") {
                    explicitEnv += ["--env", s]
                    explicitKeys.insert(String(s[..<eq]))
                } else if let value = environment[s] {
                    explicitEnv += ["--env", "\(s)=\(value)"]
                    explicitKeys.insert(s)
                } else if fileEnv[s] == nil {
                    warnings.append("\(key): environment variable \(s) is not set — omitted")
                }
            }
        case nil: break
        default: warnings.append("\(key): unrecognized environment format — ignored")
        }
        for k in fileEnv.keys.sorted() where !explicitKeys.contains(k) {
            process += ["--env", "\(k)=\(fileEnv[k] ?? "")"]
        }
        process += explicitEnv

        if let user = svc["user"] as? String { process += ["--user", user] }
        if let workdir = svc["working_dir"] as? String { process += ["--workdir", workdir] }

        // ports: "H:C[/proto]" short form or long form mappings
        for port in svc["ports"] as? [Any] ?? [] {
            if let s = port as? String {
                var spec = s
                if let slash = spec.firstIndex(of: "/") {
                    let proto = spec[spec.index(after: slash)...]
                    if proto != "tcp" { warnings.append("\(key): port \(s) — only tcp is supported, publishing as tcp") }
                    spec = String(spec[..<slash])
                }
                let parts = spec.split(separator: ":").map(String.init)
                switch parts.count {
                case 2: management += ["--publish", "\(parts[0]):\(parts[1])"]
                case 3...: management += ["--publish", spec]  // IP:host:container — the IP may itself contain colons ("[::1]"), pass through verbatim
                default: warnings.append("\(key): port \"\(s)\" — container-only ports need an explicit host port; ignored")
                }
            } else if let m = port as? [String: Any],
                      let target = m["target"] {
                if let published = m["published"] {
                    var spec = "\(scalarString(published)):\(scalarString(target))"
                    if let ip = m["host_ip"] {
                        let host = scalarString(ip)
                        // IPv6 host addresses need brackets or the platform's
                        // publish parser rejects the whole spec.
                        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
                        spec = "\(bracketed):\(spec)"
                    }
                    management += ["--publish", spec]
                } else {
                    warnings.append("\(key): port target \(scalarString(target)) has no published port — ignored")
                }
            }
        }

        // volumes: short "src:dst[:ro]" or long form
        for vol in svc["volumes"] as? [Any] ?? [] {
            if let s = vol as? String {
                var parts = s.split(separator: ":").map(String.init)
                var readonly = false
                if parts.count == 3 {
                    readonly = parts[2].split(separator: ",").contains("ro")
                    parts.removeLast()
                }
                guard parts.count == 2 else {
                    warnings.append("\(key): volume \"\(s)\" — anonymous volumes not supported; ignored")
                    continue
                }
                management += ["--mount", mountSpec(source: parts[0], target: parts[1], readonly: readonly, baseDir: baseDir)]
            } else if let m = vol as? [String: Any],
                      let type = m["type"] as? String, let target = m["target"] as? String {
                let source = m["source"] as? String ?? ""
                let readonly = (m["read_only"] as? Bool) ?? false
                switch type {
                // Spelled out rather than `case "bind", "volume" where …`: a
                // `where` binds only to the pattern it follows, which reads as
                // if it guarded both. A bind always maps; a named volume needs
                // a source (an anonymous one falls to the default warning).
                case "bind":
                    management += ["--mount", mountSpec(source: source, target: target, readonly: readonly, baseDir: baseDir)]
                case "volume" where !source.isEmpty:
                    management += ["--mount", mountSpec(source: source, target: target, readonly: readonly, baseDir: baseDir)]
                case "tmpfs":
                    management += ["--tmpfs", target]
                default:
                    warnings.append("\(key): volume type \"\(type)\" not supported — ignored")
                }
            }
        }

        // networks: list or map form; "default" means the platform default (no flag)
        var networkRefs: [String] = []
        switch svc["networks"] {
        case let list as [Any]: networkRefs = list.map { scalarString($0) }
        case let map as [String: Any]: networkRefs = map.keys.sorted()
        case nil: break
        default: warnings.append("\(key): unrecognized networks format — ignored")
        }
        for net in networkRefs where net != "default" {
            if !declaredNetworks.contains(net) {
                warnings.append("\(key): network \"\(net)\" not declared top-level — will be created")
            }
            management += ["--network", net]
        }
        if networkRefs.filter({ $0 != "default" }).count > 1 {
            warnings.append("\(key): multiple networks — the platform attaches all, but cross-network aliasing is not supported")
        }

        // resources: v2 keys or v3 deploy.resources.limits
        if let cpus = svc["cpus"] { resource += ["--cpus", scalarString(cpus)] }
        if let mem = svc["mem_limit"] { resource += ["--memory", scalarString(mem)] }
        if let deploy = svc["deploy"] as? [String: Any],
           let resources = deploy["resources"] as? [String: Any],
           let limits = resources["limits"] as? [String: Any] {
            if let cpus = limits["cpus"] { resource += ["--cpus", scalarString(cpus)] }
            if let mem = limits["memory"] { resource += ["--memory", scalarString(mem)] }
        }

        // command: string or list
        var command: [String] = []
        switch svc["command"] {
        case let s as String: command = shellSplit(s)
        case let list as [Any]: command = list.map { scalarString($0) }
        case nil: break
        default: warnings.append("\(key): unrecognized command format — ignored")
        }

        // entrypoint: the platform takes a single executable string where
        // docker takes a full argv — approximate the list form by passing the
        // head as --entrypoint and PREPENDING the rest to the command argv;
        // the resulting in-container argv matches docker's entrypoint +
        // command (and, like docker, an entrypoint override suppresses the
        // image CMD unless command: is set). A string form is shell-split
        // first, so a single word maps to --entrypoint verbatim. Docker's
        // empty "clear the image entrypoint" form can't be expressed.
        var entrypoint: [String] = []
        switch svc["entrypoint"] {
        case let s as String:
            entrypoint = shellSplit(s)
            if entrypoint.isEmpty { warnings.append("\(key): entrypoint is empty — ignored") }
        case let list as [Any]:
            entrypoint = list.map { scalarString($0) }
            if entrypoint.isEmpty { warnings.append("\(key): entrypoint is empty — ignored") }
        case nil: break
        default: warnings.append("\(key): unrecognized entrypoint format — ignored")
        }
        if let head = entrypoint.first {
            management += ["--entrypoint", head]
            command = Array(entrypoint.dropFirst()) + command
        }

        // depends_on: list form (→ started) or map with condition
        var deps: [String: DependsCondition] = [:]
        switch svc["depends_on"] {
        case let list as [Any]:
            for entry in list { deps[scalarString(entry)] = .started }
        case let map as [String: Any]:
            for (dep, spec) in map.sorted(by: { $0.key < $1.key }) {
                var condition = DependsCondition.started
                if let m = spec as? [String: Any] {
                    if let raw = m["condition"] as? String {
                        if let parsed = DependsCondition(rawValue: raw) {
                            condition = parsed
                        } else {
                            warnings.append("\(key): depends_on \(dep) condition \"\(raw)\" is unknown — treating as service_started")
                        }
                    }
                    if (m["required"] as? Bool) == false {
                        warnings.append("\(key): depends_on \(dep) \"required: false\" is not supported — dependency treated as required")
                    }
                }
                deps[dep] = condition
            }
        case nil: break
        default: break
        }

        // profiles: list of strings; filtering happens in Plan.selecting
        var profiles: [String] = []
        switch svc["profiles"] {
        case let list as [Any]: profiles = list.map { scalarString($0) }
        case nil: break
        default: warnings.append("\(key): unrecognized profiles format — ignored")
        }

        var healthcheck: Healthcheck? = nil
        switch svc["healthcheck"] {
        case let hc as [String: Any]: healthcheck = parseHealthcheck(key: key, hc: hc, warnings: &warnings)
        case nil: break
        default: warnings.append("\(key): unrecognized healthcheck format — ignored")
        }

        // stop_grace_period / stop_signal: applied by down/stop, not at run time
        var stopGrace: Double? = nil
        if let raw = svc["stop_grace_period"] {
            if let seconds = parseDuration(scalarString(raw)) {
                stopGrace = seconds
            } else {
                warnings.append("\(key): stop_grace_period \"\(scalarString(raw))\" is not a duration — using the default")
            }
        }
        let stopSignal = svc["stop_signal"].map(scalarString)

        // Everything we understand is handled above; name the rest honestly.
        let handled: Set<String> = [
            "image", "container_name", "environment", "env_file", "user", "working_dir",
            "ports", "volumes", "networks", "cpus", "mem_limit", "deploy", "command",
            "entrypoint", "depends_on", "profiles", "healthcheck", "stop_grace_period",
            "stop_signal", "build",
        ]
        for k in svc.keys.sorted() where !handled.contains(k) {
            warnings.append("\(key): \"\(k)\" is not supported — ignored")
        }

        management += ["--label", "\(Compose.projectLabel)=\(project)"]

        let plan = ServicePlan(
            service: key, name: name, image: image,
            processArgs: process, managementArgs: management,
            resourceArgs: resource, commandArgs: command,
            profiles: profiles, healthcheck: healthcheck, dependsOn: deps,
            stopGracePeriod: stopGrace, stopSignal: stopSignal, build: buildSpec)
        return (plan, warnings)
    }

    /// nil (no probe) for `disable: true`, `test: NONE`, or an unusable test.
    private static func parseHealthcheck(key: String, hc: [String: Any], warnings: inout [String]) -> Healthcheck? {
        if (hc["disable"] as? Bool) == true { return nil }
        var test: [String] = []
        var shellForm = false
        switch hc["test"] {
        case let s as String:
            test = [s]; shellForm = true
        case let list as [Any]:
            let parts = list.map { scalarString($0) }
            switch parts.first {
            case "NONE": return nil
            case "CMD": test = Array(parts.dropFirst())
            case "CMD-SHELL": test = Array(parts.dropFirst()); shellForm = true
            default:
                warnings.append("\(key): healthcheck test must start with CMD, CMD-SHELL or NONE — ignored")
                return nil
            }
        default:
            warnings.append("\(key): healthcheck has no test — ignored")
            return nil
        }
        if test.isEmpty {
            warnings.append("\(key): healthcheck test is empty — ignored")
            return nil
        }
        func duration(_ field: String, default def: Double) -> Double {
            guard let raw = hc[field] else { return def }
            if let seconds = parseDuration(scalarString(raw)) { return seconds }
            warnings.append("\(key): healthcheck \(field) \"\(scalarString(raw))\" is not a duration — using default")
            return def
        }
        var retries = 3
        if let raw = hc["retries"] {
            if let n = (raw as? Int) ?? Int(scalarString(raw)) {
                retries = n
            } else {
                warnings.append("\(key): healthcheck retries \"\(scalarString(raw))\" is not an integer — using default")
            }
        }
        // The engine treats zero interval/timeout/retries as "unset" — same here,
        // so an explicit `interval: 0s` can't turn the prober into a hot loop.
        let interval = duration("interval", default: 30)
        let timeout = duration("timeout", default: 30)
        return Healthcheck(
            test: test, shellForm: shellForm,
            interval: interval > 0 ? interval : 30,
            timeout: timeout > 0 ? timeout : 30,
            retries: retries > 0 ? retries : 3,
            startPeriod: duration("start_period", default: 0))
    }

    // MARK: helpers
    /// Parse a compose `build:` value (string context, or a map with context/
    /// dockerfile/args). Returns nil when there's no build key. Paths resolve
    /// against the compose file's directory. The produced tag is the explicit
    /// image if given, else <service>:latest.
    private static func parseBuild(
        _ raw: Any?, service: String, project: String, image: String?,
        baseDir: String?, warnings: inout [String]
    ) throws -> BuildSpec? {
        guard let raw else { return nil }
        func abs(_ path: String) -> String {
            if path.hasPrefix("/") { return path }
            let base = baseDir ?? FileManager.default.currentDirectoryPath
            return URL(fileURLWithPath: base).appendingPathComponent(path).standardizedFileURL.path
        }
        var context = "."
        var dockerfile: String? = nil
        var args: [String] = []
        switch raw {
        case let str as String:
            context = str
        case let map as [String: Any]:
            if let c = map["context"] as? String { context = c }
            if let d = map["dockerfile"] as? String { dockerfile = d }
            switch map["args"] {
            case let list as [Any]: args = list.map(scalarString)
            case let m as [String: Any]:
                for (k, v) in m.sorted(by: { $0.key < $1.key }) { args.append("\(k)=\(scalarString(v))") }
            default: break
            }
            for k in map.keys where !["context", "dockerfile", "args"].contains(k) {
                warnings.append("\(service): build.\(k) is not supported — ignored")
            }
        default:
            warnings.append("\(service): unrecognized build value — ignored")
            return nil
        }
        let contextAbs = abs(context)
        // docker resolves `dockerfile` relative to the CONTEXT dir, not the
        // compose file; an absolute dockerfile is honored as-is.
        let dockerfileAbs: String
        if let dockerfile {
            dockerfileAbs = dockerfile.hasPrefix("/")
                ? dockerfile
                : URL(fileURLWithPath: contextAbs).appendingPathComponent(dockerfile).standardizedFileURL.path
        } else {
            dockerfileAbs = "\(contextAbs)/Dockerfile"
        }
        let tag = image ?? "\(service):latest"
        return BuildSpec(context: contextAbs, dockerfile: dockerfileAbs, tag: tag, args: args)
    }


    private static func mountSpec(source: String, target: String, readonly: Bool, baseDir: String?) -> String {
        let isBind = source.hasPrefix("/") || source.hasPrefix("~") || source.hasPrefix("./") || source.hasPrefix("../")
        var src = isBind ? (source as NSString).expandingTildeInPath : source
        if isBind, !src.hasPrefix("/") {
            // Compose resolves relative binds against the compose file's directory.
            src = URL(fileURLWithPath: baseDir ?? FileManager.default.currentDirectoryPath)
                .appendingPathComponent(src).standardizedFileURL.path
        }
        var spec = "type=\(isBind ? "bind" : "volume"),source=\(src),target=\(target)"
        if readonly { spec += ",readonly" }
        return spec
    }

    /// Kahn topological sort over depends_on; deterministic (sorted) tie-breaks.
    private static func topoSort(services: [String], dependsOn: [String: [String]]) throws -> [String] {
        for (svc, deps) in dependsOn {
            for d in deps where !dependsOn.keys.contains(d) && !services.contains(d) {
                throw Error.unknownDependency(service: svc, dependsOn: d)
            }
        }
        var remaining = Set(services)
        var ordered: [String] = []
        while !remaining.isEmpty {
            let ready = remaining
                .filter { svc in (dependsOn[svc] ?? []).allSatisfy { !remaining.contains($0) } }
                .sorted()
            if ready.isEmpty { throw Error.dependencyCycle(remaining.sorted()) }
            ordered += ready
            remaining.subtract(ready)
        }
        return ordered
    }

    private static func scalarString(_ v: Any) -> String {
        if let b = v as? Bool { return b ? "true" : "false" }
        return String(describing: v)
    }

    /// Go-style duration ("300ms", "5s", "1m30s", "2h") → seconds.
    public static func parseDuration(_ s: String) -> Double? {
        let multipliers: [String: Double] = ["ms": 0.001, "s": 1, "m": 60, "h": 3600]
        var total = 0.0
        var number = ""
        var unit = ""
        for ch in s {
            if ch.isNumber || ch == "." {
                if !unit.isEmpty {
                    guard let n = Double(number), let m = multipliers[unit] else { return nil }
                    total += n * m
                    number = ""; unit = ""
                }
                number.append(ch)
            } else if !number.isEmpty {
                unit.append(ch)
            } else {
                return nil
            }
        }
        guard let n = Double(number), let m = multipliers[unit] else { return nil }
        return total + n * m
    }

    /// Minimal shell-style splitter for compose string commands (quotes honored).
    public static func shellSplit(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character? = nil
        var started = false
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; started = true
            } else if ch == " " || ch == "\t" {
                if started { out.append(current); current = ""; started = false }
            } else {
                current.append(ch); started = true
            }
        }
        if started { out.append(current) }
        return out
    }

    public static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        if s.range(of: "^[A-Za-z0-9._:/=@,+-]+$", options: .regularExpression) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

