import Foundation
import Darwin

/// One process entry for the details window.
public struct ProcessUsage: Sendable, Identifiable {
    public let pid: Int32
    public let name: String
    /// CPU usage in percent of one core (can exceed 100 for multithreaded processes).
    public let cpuPercent: Double
    /// Physical memory footprint in bytes.
    public let memoryBytes: UInt64

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, cpuPercent: Double, memoryBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

public enum ProcessSort: Sendable {
    case cpu
    case memory
}

/// Process list for the details window.
///
/// Names and CPU come from `ps` (setuid root, so system daemons are included).
/// Memory is `phys_footprint` via `proc_pid_rusage`; for root-owned processes
/// that call is denied, so a one-time `top` snapshot per window supplies their
/// footprint. This keeps the 1-second refresh cheap while matching Activity
/// Monitor's memory numbers much more closely than RSS.
public final class ProcessSampler {
    private var rootFootprints: [Int32: UInt64] = [:]

    public init() {}

    public func reset() {
        rootFootprints.removeAll()
    }

    public func sample() -> [ProcessUsage] {
        let rows = Self.psRows()
        if rootFootprints.isEmpty {
            rootFootprints = Self.topFootprints()
        }

        return rows.map { row in
            let footprint = Self.footprint(row.pid)
                ?? rootFootprints[row.pid]
                ?? row.memoryBytes
            return ProcessUsage(
                pid: row.pid,
                name: row.name,
                cpuPercent: row.cpuPercent,
                memoryBytes: footprint
            )
        }
    }

    public static func top(
        _ usages: [ProcessUsage],
        by sort: ProcessSort,
        limit: Int = 10
    ) -> [ProcessUsage] {
        guard limit > 0 else { return [] }
        let sorted = usages.sorted { lhs, rhs in
            switch sort {
            case .cpu:
                if lhs.cpuPercent == rhs.cpuPercent { return lhs.name < rhs.name }
                return lhs.cpuPercent > rhs.cpuPercent
            case .memory:
                if lhs.memoryBytes == rhs.memoryBytes { return lhs.name < rhs.name }
                return lhs.memoryBytes > rhs.memoryBytes
            }
        }
        return Array(sorted.prefix(limit))
    }

    // MARK: - ps / top / footprint

    private static func psRows() -> [ProcessUsage] {
        guard let result = run("/bin/ps", ["-Ao", "pid=,pcpu=,rss=,comm="]) else {
            return []
        }
        return parsePS(result.output).filter { $0.pid != result.pid }
    }

    private static func topFootprints() -> [Int32: UInt64] {
        guard let result = run("/usr/bin/top", [
            "-l", "1",
            "-o", "mem",
            "-n", "1000",
            "-stats", "pid,mem",
        ]) else {
            return [:]
        }
        return parseTopMemory(result.output).filter { $0.key != result.pid }
    }

    private static func footprint(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        return info.ri_phys_footprint
    }

    private static func run(
        _ path: String,
        _ arguments: [String]
    ) -> (output: String, pid: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            return nil
        }

        let pid = process.processIdentifier
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return (String(decoding: data, as: UTF8.self), pid)
    }

    /// Parses `ps -Ao pid=,pcpu=,rss=,comm=` output.
    static func parsePS(_ output: String) -> [ProcessUsage] {
        var usages: [ProcessUsage] = []
        for line in output.split(separator: "\n") {
            let fields = line
                .split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 4,
                  let pid = Int32(fields[0]),
                  pid > 0,
                  let cpu = Double(fields[1]),
                  let rssKB = UInt64(fields[2]) else {
                continue
            }

            let command = fields[3]
            let name = URL(fileURLWithPath: command).lastPathComponent
            usages.append(ProcessUsage(
                pid: pid,
                name: name.isEmpty ? "PID \(pid)" : name,
                cpuPercent: cpu,
                memoryBytes: rssKB * 1024
            ))
        }
        return usages
    }

    /// Parses `top -l 1 ... -stats pid,mem` output.
    static func parseTopMemory(_ output: String) -> [Int32: UInt64] {
        var footprints: [Int32: UInt64] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2,
                  let pid = Int32(fields[0]),
                  pid > 0,
                  let memory = parseMemory(fields[1]) else {
                continue
            }
            footprints[pid] = memory
        }
        return footprints
    }

    static func parseMemory(_ text: Substring) -> UInt64? {
        var value = text
        while let last = value.last, last == "+" || last == "-" {
            value = value.dropLast()
        }
        guard let unit = value.last, let amount = Double(value.dropLast()) else {
            return nil
        }
        switch unit {
        case "K": return UInt64(amount * 1024)
        case "M": return UInt64(amount * 1024 * 1024)
        case "G": return UInt64(amount * 1024 * 1024 * 1024)
        case "B": return UInt64(amount)
        default: return nil
        }
    }
}
