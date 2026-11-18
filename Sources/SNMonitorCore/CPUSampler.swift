import Foundation
import Darwin

/// Reads system-wide CPU load from Mach and computes usage from tick deltas.
/// Not thread-safe: use from a single sampling queue.
public final class CPUSampler {
    private var previousTicks: [UInt64]?
    private let coreCount = ProcessInfo.processInfo.processorCount

    public init() {}

    public func reset() {
        previousTicks = nil
    }

    public func sample() -> CPUSnapshot {
        var loads = [Double](repeating: 0, count: 3)
        loads.withUnsafeMutableBufferPointer { buffer in
            _ = getloadavg(buffer.baseAddress, 3)
        }

        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }

        let ticks = [
            UInt64(info.cpu_ticks.0), // user
            UInt64(info.cpu_ticks.1), // system
            UInt64(info.cpu_ticks.2), // idle
            UInt64(info.cpu_ticks.3), // nice
        ]

        let previous = previousTicks
        previousTicks = ticks

        var snapshot = CPUSnapshot(
            usage: 0, user: 0, system: 0, idle: 1,
            loadAverage1: loads[0], loadAverage5: loads[1], loadAverage15: loads[2],
            coreCount: coreCount
        )

        guard kr == KERN_SUCCESS, let previous else { return snapshot }

        let deltas = zip(ticks, previous).map(Self.wrapDelta)
        let total = deltas.reduce(0, +)
        guard total > 0 else { return snapshot }

        let user = deltas[0] + deltas[3] // nice is attributed to user time
        let system = deltas[1]
        let idle = deltas[2]
        let busy = user + system

        snapshot.usage = Double(busy) / Double(total)
        snapshot.user = Double(user) / Double(total)
        snapshot.system = Double(system) / Double(total)
        snapshot.idle = Double(idle) / Double(total)
        return snapshot
    }

    /// Tick counters are 32-bit and wrap after roughly 497 days of uptime.
    static func wrapDelta(_ now: UInt64, _ previous: UInt64) -> UInt64 {
        now >= previous ? now - previous : (UInt64(UInt32.max) + 1) - previous + now
    }
}
