import Foundation

// MARK: - Selection

extension Compose.Plan {
    /// Docker-style service selection: the named services plus their transitive
    /// depends_on closure, kept in start order. Profiles filter first (a service
    /// without profiles is always enabled; profile `"*"` activates every one);
    /// naming a service explicitly activates its own profiles (docker v2), but a
    /// dependency pulled in by closure whose profiles all stay inactive is an
    /// error. Created volumes/networks are pruned to what the selected services
    /// reference. Empty `services` = every enabled one.
    /// `includeDependencies: false` keeps EXACTLY the named services — docker's
    /// scoping for stop/start/restart/pull/ps, where pulling in a dependency
    /// would stop a db that other services still use.
    func selecting(
        services requested: [String], activeProfiles: [String], includeDependencies: Bool = true
    ) throws -> Compose.Plan {
        let byName = Dictionary(uniqueKeysWithValues: services.map { ($0.service, $0) })
        for name in requested where byName[name] == nil {
            throw Compose.Error.noSuchService(name)
        }
        var active = Set(activeProfiles)
        for name in requested { active.formUnion(byName[name]?.profiles ?? []) }
        func enabled(_ svc: Compose.ServicePlan) -> Bool {
            svc.profiles.isEmpty || active.contains("*") || svc.profiles.contains(where: active.contains)
        }

        var selected = Set<String>()
        var queue = requested.isEmpty ? services.filter(enabled).map(\.service) : requested
        while let name = queue.popLast() {
            guard !selected.contains(name), let svc = byName[name] else { continue }
            if !enabled(svc) {
                throw Compose.Error.inactiveProfile(service: name, profile: svc.profiles.first ?? "?")
            }
            selected.insert(name)
            if includeDependencies { queue += svc.dependsOn.keys.sorted() }
        }

        let kept = services.filter { selected.contains($0.service) }
        let volumeRefs = Set(kept.flatMap(\.volumeRefs))
        let networkRefs = Set(kept.flatMap(\.networkRefs))
        return Compose.Plan(
            project: project,
            volumes: volumes.filter(volumeRefs.contains),
            networks: networks.filter(networkRefs.contains),
            externalVolumes: externalVolumes,
            externalNetworks: externalNetworks,
            services: kept,
            allServices: allServices,
            warnings: warnings)
    }
}

