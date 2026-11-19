# Changelog

All notable changes to this project will be documented in this file.

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
