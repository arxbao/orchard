# Orchard

**A native macOS UI for Apple's [container](https://github.com/apple/container) platform** — manage Linux-containers-as-lightweight-VMs from a clean SwiftUI interface, with a headless CLI for scripting.

Built entirely in SwiftUI (no Electron). Orchard links Apple's own **`ContainerAPIClient`** and talks to `container-apiserver` **directly over XPC** — the same wire path the `container` CLI uses; the CLI binary is never invoked.

> Inspired by and based on [davit](https://github.com/wouterdebie/davit) (MIT). Orchard keeps davit's proven service/state-layer design while restructuring it into a testable, modular architecture.

## Features

- **Dashboard** — service status with one-click start/stop, resource counts, disk usage, live aggregate CPU chart.
- **Containers** — list with live CPU/memory/IP per row; start/stop/kill/restart/delete; search; export filesystem; **Edit & Recreate**. Detail view with Overview / Logs (streaming) / Stats (Swift Charts) / Inspect / Terminal / Files tabs.
- **Images** — pull with streaming progress, Pull Latest, tag, delete, prune, build via BuildKit, per-image layers.
- **Compose** — parse/preview/import compose files; `plan | up | down | ps | logs | stop | start | restart | pull | exec`; honors `profiles`, `depends_on` conditions, `healthcheck`, `.env` interpolation.
- **Machines** — Apple container machines: create/size/boot/stop/delete/edit, terminal, live stats.
- **Volumes / Networks** — create, delete, prune, browse volume files.
- **Registries** — sign in to Docker Hub / ghcr.io / any registry (credentials in keychain), docker credential helpers honored.
- **Menu bar extra** — service status and per-container quick actions from anywhere.
- **Global search** — ⌘K palette; **deep links** — `orchard://container/<id>`.
- **CLI** — `orchard run | compose | machine | build | exec | pull | registry | system | selftest` (same backend as the GUI).

## Requirements

- Apple silicon Mac, macOS 15+ (macOS 26 recommended — matches `container` 1.3)
- [apple/container](https://github.com/apple/container/releases) platform installed (Orchard bootstraps it on first launch)

## Architecture

```
container-apiserver (system launchd service)
        │ XPC (ContainerAPIClient — the only channel)
OrchardCore (local Swift package: services, models, compose parsing — unit-testable without a daemon)
        ├── orchard.app (SwiftUI GUI: AppState facade + views)
        └── orchard-cli (ArgumentParser commands: run/compose/machine/...)
```

- **OrchardCore** — service layer split by domain (`ContainerService`, `MachineService`, `BuildService`, `RegistryService`, `ComposeParser`…), models, and errors. Pure logic (compose parsing, flag routing, stats math, log scanning) is extracted for unit testing.
- **orchard.app** — SwiftUI app; AppState facade internally delegates to per-domain stores.
- **orchard-cli** — headless entry point sharing the exact same OrchardCore backend.

## Build & run

```sh
# GUI (Xcode project)
open orchard.xcodeproj
# or build the app and run from Products/

# CLI
cd Packages/OrchardCore && swift run orchard-cli --help

# Unit tests (no daemon required)
xcodebuild test -scheme orchard -destination 'platform=macOS'
```

## License

MIT. This project reuses code from [davit](https://github.com/wouterdebie/davit) (MIT, Copyright © 2026 Wouter de Bie) — see [LICENSE](LICENSE).
