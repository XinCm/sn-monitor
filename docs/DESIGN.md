# sn-monitor 设计说明

## 目标

一个常驻菜单栏的 macOS 系统监视器，显示 CPU、内存、磁盘、刷新率、温度，尽量轻量：

- 原生 Swift，无第三方依赖
- 常驻 footprint 约 11 MB，面板打开约 23–26 MB
- 1 秒采样；空闲时 CPU 约 0.25–0.35% 单核
- 一键 `make build` 打包 `.app`

## 形态

- 菜单栏显示 CPU + 内存（默认），可切换为包含温度、仅 CPU、仅图标
- 点击状态项打开 NSPopover 面板：5 行指标 + 最近 120 个采样的折线
- 面板顶部「详情 ›」打开进程详情窗口：CPU / 内存 Top 10，每秒刷新
- 右键或面板齿轮打开设置：刷新间隔、菜单栏内容、Dock、开机启动、关于、退出
- `⌃⌥M` 全局快捷键开关面板
- 菜单栏空间不足时（图标被刘海遮住）自动启用 Dock 图标兜底

## 架构

```
Sources/
├── SNMonitorCore/          纯采样库，无 UI
│   ├── Models.swift        Snapshot 与格式化
│   ├── CPUSampler.swift    host_statistics 差值
│   ├── MemorySampler.swift host_statistics64 + sysctl
│   ├── DiskSampler.swift   容量缓存 + 物理盘 I/O
│   ├── DisplaySampler.swift
│   ├── SMCClient.swift     80 字节 AppleSMC ABI
│   ├── ThermalSampler.swift 候选 key 探测 + 2s 缓存
│   ├── ProcessSampler.swift libproc 进程 CPU / 内存 Top 10
│   ├── MetricsCollector.swift
│   └── MetricsEngine.swift DispatchSourceTimer
├── SNMonitorApp/           AppKit 状态栏与自绘面板
└── snctl/                  命令行工具
```

`MetricsEngine` 在私有串行队列上以 `DispatchSourceTimer`（leeway 200ms）采样，生成不可变 `Snapshot` 后回主线程更新 UI。面板关闭时不更新图表。

## 数据源

| 指标 | 数据源 | 备注 |
| --- | --- | --- |
| CPU | `host_statistics(HOST_CPU_LOAD_INFO)` | tick 差值；user(+nice)/system/idle；另取 load average |
| 内存 | `host_statistics64(HOST_VM_INFO64)` | App(internal - purgeable) + wired + compressed；swap 与压力来自 sysctl |
| 磁盘容量 | `URLResourceValues` | 与 Finder/df 一致；30s 缓存 |
| 磁盘吞吐 | `IOBlockStorageDriver.Statistics` | 只统计整块物理盘，过滤磁盘镜像和 APFS 虚拟盘 |
| 刷新率 | `CGDisplayCopyDisplayMode` | 主显示器名义刷新率 |
| 温度 | AppleSMC（私有 IOKit API） | 启动探测候选 key；CPU 取 4 个、GPU 2 个、电池 1 个；2s 刷新 |
| 进程 Top 10 | `ps` + `proc_pid_rusage` + 一次 `top` 快照 | 名称/CPU 来自 ps（含 root 系统进程）；内存为 footprint；仅详情窗口打开时采样 |

单位：内存用二进制（24.0 GB = 24 GiB），磁盘用十进制（685 GB），速率用二进制。

## 温度

- 不同芯片/系统的 SMC key 不同（本机 M5 没有常见的 `Tp09`），因此运行时探测，不硬编码
- 探测时读取所有候选，保留最热的若干传感器，之后只读这些 key
- 读不到时显示 `—`，不影响其他指标
- SMC 是私有 API，不能上架 App Store

### 进程详情

- 打开窗口后创建独立的 `ProcessSampler` 和 1s 定时器，关闭窗口即停止
- 名称/CPU 来自 `/bin/ps`：普通用户用 `proc_pidinfo` 读不到 root 进程，会把 fseventsd、WindowServer 漏掉；ps 是 setuid root，能给出完整排行。CPU 是 ps 的近期平均值
- 内存优先用 `proc_pid_rusage` 的 `ri_phys_footprint`（活动监视器口径），而不是 RSS
- root 进程的 rusage 会失败，因此在窗口打开时跑一次 `top -l 1 -stats pid,mem` 取得它们的 footprint 并缓存；之后每秒只跑 ps + rusage（约 50ms），不在循环里跑 top（top 单次约 0.8s CPU）
- 详情窗口按需打开，属可接受的额外开销；常驻状态仍保持约 11 MB

## 资源占用（M5 / macOS 26 实测）

| 状态 | footprint | CPU（单核） |
| --- | --- | --- |
| 面板关闭 | 11.1–11.5 MB | 0.25–0.34% |
| 面板打开 | 23–26 MB | 0.55–0.80% |
| 详情窗口 | 约 80 MB（重绘时） | 1.6–2.5% |
| 单次采样 | — | 0.6–3 ms |

菜单栏文字重绘是最大单项成本。图标被遮挡时会跳过重绘。

## 构建

- `swift build` / `swift test`：标准 SwiftPM 流程
- `make build`：release 构建 + 组装 `dist/sn-monitor.app` + ad-hoc 签名
- `scripts/package-app.sh` 负责复制 Info.plist、图标和可执行文件

## 已知限制

- 温度传感器为代表性采样，不是每核精确值，且 2 秒更新一次
- 刷新率是名义值，不反映 ProMotion 动态帧率
- 只统计内置/外接整块物理盘的 I/O，磁盘镜像不计
- 菜单栏满时图标会被系统隐藏，需要 Dock/快捷键兜底或精简菜单栏
