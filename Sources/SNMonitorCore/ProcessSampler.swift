import Foundation
import Darwin

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

/// Reads per-process CPU and memory with libproc.
///
/// CPU percentages are deltas of `proc_taskinfo` times, so the first sample is
/// always 0%; call `reset()` before starting a new observation window.
/// Not thread-safe: use from a single sampling queue.
public final class ProcessSampler {
    private var previousCPUTicks: [Int32: UInt64] = [:]
    private var previousTimestamp: UInt64?
    private var nameCache: [Int32: String] = [:]
    private let timebase: mach_timebase_info_data_t

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = info
    }

    public func reset() {
        previousCPUTicks.removeAll()
        previousTimestamp = nil
        nameCache.removeAll()
    }

    public func sample() -> [ProcessUsage] {
        let now = DispatchTime.now().uptimeNanoseconds
        let wallNanos = previousTimestamp.map { Double(now - $0) } ?? 0
        var currentTicks: [Int32: UInt64] = [:]
        var currentNames: [Int32: String] = [:]
        var usages: [ProcessUsage] = []

        for pid in Self.listPIDs() {
            guard let info = Self.taskInfo(pid) else { continue }
            let ticks = info.pti_total_user + info.pti_total_system
            currentTicks[pid] = ticks

            var percent = 0.0
            if wallNanos > 50_000_000,
               let previous = previousCPUTicks[pid],
               ticks > previous {
                percent = Self.percent(
                    previous: previous,
                    current: ticks,
                    wallNanos: wallNanos,
                    timebase: timebase
                )
            }

            let name = nameCache[pid] ?? Self.resolveName(of: pid)
            currentNames[pid] = name
            usages.append(ProcessUsage(
                pid: pid,
                name: name,
                cpuPercent: percent,
                memoryBytes: info.pti_resident_size
            ))
        }

        previousCPUTicks = currentTicks
        nameCache = currentNames
        previousTimestamp = now
        return usages
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

    static func percent(
        previous: UInt64,
        current: UInt64,
        wallNanos: Double,
        timebase: mach_timebase_info_data_t
    ) -> Double {
        guard current > previous, wallNanos > 0 else { return 0 }
        let deltaTicks = Double(current - previous)
        let deltaNanos = deltaTicks * Double(timebase.numer) / Double(timebase.denom)
        return deltaNanos / wallNanos * 100
    }

    // MARK: - libproc

    private static func listPIDs() -> [Int32] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }

        let capacity = max(64, Int(byteCount) / MemoryLayout<pid_t>.size + 32)
        var pids = [pid_t](repeating: 0, count: capacity)
        let used = proc_listpids(
            UInt32(PROC_ALL_PIDS),
            0,
            &pids,
            Int32(capacity * MemoryLayout<pid_t>.size)
        )
        guard used > 0 else { return [] }

        let count = min(capacity, Int(used) / MemoryLayout<pid_t>.size)
        var seen = Set<pid_t>()
        return pids.prefix(count).filter { pid in
            pid > 0 && seen.insert(pid).inserted
        }
    }

    private static func taskInfo(_ pid: Int32) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        return result == size ? info : nil
    }

    private static func resolveName(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let name = String(cString: buffer)
            if !name.isEmpty { return name }
        }

        var path = [CChar](repeating: 0, count: 1024)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let fullPath = String(cString: path)
            let last = URL(fileURLWithPath: fullPath).lastPathComponent
            if !last.isEmpty { return last }
        }

        return "PID \(pid)"
    }
}
