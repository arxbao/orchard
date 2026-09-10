# Orchard —— 苹果容器管理软件设计（借鉴 davit 重构版）

> 日期：2026-09-01
> 状态：已确认（用户批准）
> 基线：davit（MIT，https://github.com/wouterdebie/davit），基线复用其服务层/状态层设计并重构
> 跟踪基线：`4022f4f`（2026-09 同步）——container **1.3.1** / containerization **0.42.0**（CVE-2026-65388 安全补丁）、平台版本解析 fix #20、构建警告清理。
> **后续阶段（GUI/CLI）移植时一律以该 commit 或更新的 davit 版本为源**，不要用更早的代码。

## 1. 定位与设计原则

| 项 | 决策 |
|---|---|
| 定位 | 个人生产自用，开源发布（公开源码仓库 + CI） |
| 功能 | 对标 davit 全量：Containers / Images / Compose / Dashboard / Machines / Volumes·Networks / 菜单栏·搜索·深链接 / CLI 子命令 |
| 强制优化 | 架构重构 + 单测（唯一必须"比 davit 更好"的点） |
| 平台哲学 | 以 apple/container 能力为准：docker 对齐只做语法层，能力不支持就 fail loudly（继承 davit 哲学） |
| 代码来源 | 基线复用 davit（MIT 许可，合规要求保留版权声明），保留服务层/状态层设计，重构结构性短板 |
| 通信架构 | GUI 与 CLI 均经 OrchardCore 走 XPC 与 container-apiserver 通信；全程不调用 `container` 命令二进制 |
| UI 策略 | **UI 基本复刻 davit 的布局**（功能与视图结构对应），开发中发现 UI 不合理处**允许优化**；验收以"功能可用、操作流畅"为准 |
| 注释规范 | 代码须加注释：每个类型/方法/关键代码块写明**设计意图与原因**（继承 davit 的注释风格：解释"为什么"而非"是什么"）；公共 API 必须有文档注释；易踩坑处（上游 bug、平台限制）注明 workaround |
| 知识索引 | 每个功能完成并经测试后运行 `codegraph sync`（本机 `/Users/xlee7/.local/bin/codegraph`）更新 `.codegraph/` 索引，供后续开发与子 agent 检索使用 |
| 明确不做 | 自动更新 / 公证 / DMG 发布 / Homebrew / 文档站；体验增强（批量操作、健康徽章）与 compose 并行化列入"后续可选" |

## 2. 工程结构（方案 A'：Core 为 local Swift package）

```
orchard/                          (git repo: main + dev + feature/*)
├── Packages/OrchardCore/         ← local Swift package（声明式，diff 友好）
│   ├── Package.swift             ← library: OrchardCore + executable: orchard-cli
│   ├── Sources/
│   │   ├── OrchardCore/          ← 服务层 + 模型 + compose 解析
│   │   └── orchard-cli/          ← CLI 入口（ArgumentParser 重写）
│   └── Tests/OrchardCoreTests/   ← Swift Testing 单测（唯一单测入口，swift test 跑）
├── orchard/                      ← App target（SwiftUI GUI）
│   ├── orchardApp.swift          ← @main 唯一 GUI 入口
│   ├── AppState/                 ← AppState 门面 + 领域 Store
│   ├── Views/                    ← 全部 UI（按域分目录）
│   └── Resources/                ← AppIcon、菜单栏模板图
├── .github/workflows/ci.yml      ← CI：swift test + xcodebuild build + swift build
├── LICENSE                       ← MIT，保留 davit 版权声明（合规硬要求）
├── README.md
└── orchard.xcodeproj             ← 移除模板自带 orchardTests/orchardUITests target（YAGNI：单测走 package，GUI 靠人工冒烟）
```

关键设计：
- App target 经 Xcode 引用 local package（OrchardCore）；CLI 同时保留 `swift run orchard-cli` 能力（SPM executable）。
- **已知代价（双构建系统）**：Xcode（DerivedData）与 SPM（`.build`）各自解析依赖、两套构建产物；local package 的依赖会被 fetch 两遍，首次构建较慢。可接受，属 hybrid 方案的固有成本。
- 两个入口（GUI / CLI）都调用 `Environment.bootstrap()`（统一初始化 Logging + InstallRoot + container 平台解析）。

## 3. 模块划分与文件映射（davit → orchard）

| davit 文件（现状） | orchard 去向 | 重构动作 |
|---|---|---|
| `Backend.swift`（1758 行） | `Packages/OrchardCore/Sources/OrchardCore/` | 按领域拆 7 件：`ContainerClient` / `ContainerService` / `MachineService` / `BuildService` / `RegistryService` / `Environment`(bootstrap·InstallRoot·logging) / `Errors` |
| `Compose.swift` | `.../Compose/` | 拆三件：`ComposeParser`（纯解析，可测）/ `ComposePlan` / `ComposeRunner`（执行） |
| `Models.swift` | `.../Models/` | 显式 `Sendable` |
| `AppState.swift` | `orchard/AppState/` | 保留 AppState 门面（对外 45 个调用方不动），内部重组为 ContainerStore / MachineStore / StatsStore；**跨领域协调（如容器删除→statsHistory 清理、意外停止→通知）由 AppState 门面负责，Store 之间不直接耦合** |
| `Views/`（14 文件） | `orchard/Views/` | 按视图域分目录（Containers/Images/Machines/Settings/Common） |
| `App.swift` / `Main.swift` | GUI 入口 → `orchardApp.swift`；CLI 分发 → `orchard-cli/main.swift`（ArgumentParser 重写） | `@main` 一分为二，各调 `Environment.bootstrap()` |
| `icon/`、`bundle.sh` 相关 | `orchard/Resources/` | 图标进 GUI target；bundle.sh 不迁移（直接 xcodebuild） |
| `Updater.swift`、harness、`--snapshot/--probe/--pose` | 删除 | YAGNI：个人自用砍掉 |

## 4. 入口与生命周期

- GUI：`@main struct OrchardApp: App`（Window + MenuBarExtra + Settings 场景）。
- CLI：`@main enum OrchardCLI`（ArgumentParser 子命令：run / compose / machine / build / exec / pull / registry / stats / system / selftest）。
- 初始化顺序（两个入口的第一行）：`Environment.bootstrap()` → `LoggingSystem.bootstrap`（只许一次/进程）+ `ContainerBinary.resolve()` + `setenv(InstallRoot)`。

## 5. 关键配置决策（避坑清单）

1. **并发**：Xcode target 设 `SWIFT_VERSION=5.0`，关闭 `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` 与 `SWIFT_APPROACHABLE_CONCURRENCY=YES`；**同时 Core 的 `Package.swift` 必须显式 `.swiftLanguageMode(.v5)`**（davit 原样配置）——否则 Core 按 Swift 6 编译，基线代码上千处报错。两套构建系统各自设置，缺一不可。
2. **沙盒**：App target 关闭 `ENABLE_APP_SANDBOX`（与 davit 一致；容器工具需访问 ~/.config/container、/usr/local、系统 XPC 服务）。
3. **依赖**：container `exact 1.3.0`、containerization `exact 0.41.0`（与已装 daemon 锁定，禁止 `from:`）；其余（ArgumentParser / swift-log / Yams / NIO）`from:`。
4. **Bundle.main 审计**：grep 全部 `Bundle.` 引用；`resourceURL`（vendor 路径）类逻辑改注入式（GUI 传入路径）；图标 `NSImage(named:)` 留在 GUI target。
5. **@main 唯一性**：GUI/CLI 各自独立 target，无冲突。
6. **单测入口唯一**：单测放 package `Tests/`（`swift test` 跑），Xcode 工程不设单测 target——避免两套体系；集成测试保留 CLI `selftest` 子命令（需 live daemon）。

## 6. 测试策略（davit 没有的：可进 CI 的单测）

**单测（Swift Testing，不依赖 daemon）**——**唯一入口：`Packages/OrchardCore/Tests/OrchardCoreTests/`，命令 `swift test --package-path Packages/OrchardCore`**。Xcode 工程不设单测 target（避免两套体系分叉）。第一阶段起即覆盖：
- `ComposeParser`：解析子集、拓扑排序、循环拒绝、profiles、`.env` 插值
- Flag 路由：`run` 命令 docker 标志分桶（davit `parseArgs` 纯函数迁移）
- Stats 计算：CPU% / IO 速率差分
- `StopReason` 内核日志解析
- deep-link URL 解析

**集成测试**：保留 davit `selftest` 子命令（live daemon，开发时手动跑，不进 CI）。

**GUI 验证**：不做自动化 UI 测试（YAGNI），每个阶段验收由人工冒烟覆盖。

## 7. git 工作流

```
main（稳定：只收大功能/补丁）  ←──  dev（集成分支：频繁提交汇聚点）  ←──  feature/*（每个功能一个分支）
```

- 分支：`feature/<name>` 每功能一分支；dev 为集成分支（开发中的频繁提交只进 dev）；**main 只接受"大功能或补丁"级别的合并**——用户可见的大功能（如 GUI 容器管理、compose 支持）或修复性补丁完成并验证后才合并 main，日常开发提交不合并 main。
- worktree 隔离：每个功能分支在 `.worktrees/<branch>/` 建独立工作区；`.worktrees/` 加入 `.gitignore` 并提交。
- 合并流程：feature 开发 → 单测通过 → 合并 dev（随时）→ CI 绿 → 大功能/补丁里程碑时合并 main。
- 本地验证命令：`swift test --package-path Packages/OrchardCore`（单测）+ `xcodebuild build`（App）+ `swift build --package-path Packages/OrchardCore`（CLI）+ 手动 GUI 冒烟。

## 8. GitHub 发布（公开源码仓库 + CI）

- **LICENSE**：MIT；必须保留 davit 的版权声明（"Copyright (c) 2026 Wouter de Bie"），附本项目版权与致谢。
- **README**：功能简介、架构说明、构建方法（xcodebuild / swift run）、使用说明、致谢 davit。
- **CI（.github/workflows/ci.yml）**：macOS runner，触发于 push/PR（dev、main）：
  1. `swift test --package-path Packages/OrchardCore`（单测，不依赖 daemon）；
  2. `xcodebuild build -scheme orchard -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`（CI 无证书，必须禁用签名，否则自动签名失败）；
  3. `swift build --package-path Packages/OrchardCore`（CLI）；
  4. 任一失败即红。
- **分支保护（用户在 GitHub 上设置）**：main 要求 PR + CI 检查通过——把"测试没问题再合并"变成强制规则。
- 不做：DMG、签名、公证、releases 资产（后续需要再加）。

## 9. 迭代顺序（功能分支规划）

| 阶段 | 功能分支 | 内容 | 验收 |
|---|---|---|---|
| 0 | `feature/orchardcore-skeleton` | 工程骨架：Core package（含 Tests/）+ App/CLI 入口 + 依赖 + 构建配置 + 移除模板测试 target + README/LICENSE/CI | `xcodebuild build` 出 App、`swift run orchard-cli` 出 usage、`swift test` 1 条单测绿、CI 文件就位 |
| 1 | `feature/core-services` | 服务层拆分移植（7 文件 + Models + Errors）。**注：含可见性 API 化（davit internal 符号 → library public，最小化原则）——这是本阶段主要工作量，不是纯搬文件** | 单测覆盖 flag 路由/Stats/StopReason |
| 2 | `feature/core-compose-parser` | ComposeParser / ComposePlan（纯解析） | 解析单测绿 |
| 3 | `feature/gui-containers` | AppState 门面 + Containers 列表/详情。**注：详情六 tab 可再拆分为独立子分支（如先 Overview/Logs/Stats，后 Inspect/Terminal/Files），避免单分支过大** | GUI 可管理真实容器 |
| 4 | `feature/gui-images` | Images + Run sheet + Build | 拉取/运行/构建可用 |
| 5 | `feature/gui-compose` | Compose 执行 + 导入 UI + CLI compose | compose up/down 可用 |
| 6 | `feature/gui-machines-volumes` | Machines + Volumes/Networks + Dashboard | 全资源管理可用 |
| 7 | `feature/gui-shell-extras` | 菜单栏 / ⌘K 搜索 / 深链接 / 开机自启 | 周边功能齐 |
| 8 | `feature/cli-complete` | CLI 全部子命令（ArgumentParser 重写） | CLI 与 GUI 功能对等 |

每阶段一个（或一组）功能分支，走完整 git 流程（第 7 节）。

## 10. 后续可选（本期不做）

- compose up 并行化（无依赖服务并行启动）
- 体验增强：批量多选操作、健康状态徽章、首次启动引导
- docker 兼容补全（--restart / --add-host / --hostname）——与"以平台为准"原则冲突，仅在平台能力出现时跟进
- DMG 发布 + 签名 + 公证（公开仓库阶段不做）
