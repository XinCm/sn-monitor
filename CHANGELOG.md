# Changelog

All notable changes to this project will be documented in this file.

## [0.2.1] - 2026-11-19

### Changed

- Command-line launches (`--no-dock`, or a process with `TERM` set) no longer
  enable the automatic Dock icon fallback. The `sn-monitor` launcher passes
  `--no-dock`; double-clicking the app still keeps the fallback.

## [0.2.0] - 2026-11-19

### Changed

- Process details now run one continuous `top` child
  (`-l 0 -s 2 -F -R -stats pid,cpu,mem`) while the window is open, instead of
  spawning `ps`/`top` every tick. CPU comes from adjacent rounds, memory from
  the `MEM` footprint column.
- The list shows PID (including `kernel_task` PID 0) and full names resolved
  from `ps` by PID.
- First round has no CPU delta, so the CPU column shows "采样中"; memory is
  available immediately.
- Refresh interval is selectable (1/2/5 s, default 2 s) in the window.
- Closing the window or quitting the app stops the `top` child; orphaned
  children from a crash are cleaned on next launch.

## [0.1.4] - 2026-11-19

### Fixed

- Process details now show **footprint** instead of RSS, so memory rankings
  match Activity Monitor much more closely. User processes use
  `proc_pid_rusage`; root processes are filled from a one-time `top` snapshot
  when the window opens. CPU keeps the complete `ps` ranking.

## [0.1.3] - 2026-11-19

### Fixed

- Process details now use `/bin/ps` instead of `proc_pidinfo`, so root-owned
  system processes (fseventsd, WindowServer, ...) are included and the ranking
  matches `ps` / Activity Monitor more closely.

## [0.1.2] - 2026-11-19

### Added

- Process details window with the top 10 processes by CPU and by memory, refreshed every second.

## [0.1.1] - 2026-11-18

### Added

- Menu bar content modes: CPU + memory (default), CPU + memory + temperature, CPU + temperature, CPU only, icon only.
- Global shortcut `⌃⌥M` to toggle the panel.
- Automatic Dock icon fallback when the menu bar item is hidden by the notch.
- "Show in Dock" and "Launch at login" settings.
- CLI `snctl` with JSON and text output.
- SwiftPM package layout, Swift Testing suite, and GitHub Actions CI.

### Changed

- Renamed the project and app from MacSystemKit to sn-monitor.
- Temperature sensors are sampled every 2 seconds; other metrics stay at 1 second.
- Disk capacity is cached for 30 seconds to avoid a 4–10 ms query per tick.

## [0.1.0] - 2026-11-17

- Initial menu bar app: CPU, memory, disk, refresh rate, and SMC temperatures.
