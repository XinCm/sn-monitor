import Foundation

/// One process entry for the details window.
public struct ProcessUsage: Sendable, Identifiable {
    public let pid: Int32
    public let name: String
    /// CPU usage in percent of one core (can exceed 100 for multithreaded processes).
    public let cpuPercent: Double
    /// Resident set size in bytes.
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
/// `ps` is used instead of `proc_pidinfo` because the latter cannot read
/// root-owned processes as a normal user; the top CPU consumer is often a
/// system daemon (fseventsd, WindowServer, ...). `ps` is setuid root on macOS
/// and therefore matches what users see in Activity Monitor / `ps`.
public final class ProcessSampler {
    public init() {}

    public func reset() {
        // No baseline is needed: `ps` already reports a recent CPU percentage.
    }

    public func sample() -> [ProcessUsage] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pid=,pcpu=,rss=,comm="]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return Self.parse(String(decoding: data, as: UTF8.self))
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

    /// Parses `ps -Ao pid=,pcpu=,rss=,comm=` output.
    static func parse(_ output: String) -> [ProcessUsage] {
        var usages: [ProcessUsage] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4,
                  let pid = Int32(fields[0]),
                  pid > 0,
                  let cpu = Double(fields[1]),
                  let rssKB = UInt64(fields[2]) else {
                continue
            }

            let command = String(fields[3])
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
}
