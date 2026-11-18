import Foundation
import Darwin

/// Reads VM statistics and presents them in an Activity Monitor-like shape.
/// Not thread-safe: use from a single sampling queue.
public final class MemorySampler {
    private let totalBytes = ProcessInfo.processInfo.physicalMemory
    private let pageSize = UInt64(vm_kernel_page_size)

    public init() {}

    public func sample() -> MemorySnapshot {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard kr == KERN_SUCCESS else {
            return MemorySnapshot(
                total: totalBytes, used: 0, cached: 0, free: totalBytes,
                swapUsed: 0, swapTotal: 0, pressure: .unknown
            )
        }

        let used = Self.usedBytes(
            internalPages: UInt64(stats.internal_page_count),
            purgeablePages: UInt64(stats.purgeable_count),
            wiredPages: UInt64(stats.wire_count),
            compressedPages: UInt64(stats.compressor_page_count),
            pageSize: pageSize
        )
        let cached = (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * pageSize
        let clampedUsed = min(used, totalBytes)
        let clampedCached = min(cached, totalBytes - clampedUsed)

        let swap = readSwapUsage()

        return MemorySnapshot(
            total: totalBytes,
            used: clampedUsed,
            cached: clampedCached,
            free: totalBytes - clampedUsed - clampedCached,
            swapUsed: swap.used,
            swapTotal: swap.total,
            pressure: readPressure()
        )
    }

    static func usedBytes(
        internalPages: UInt64,
        purgeablePages: UInt64,
        wiredPages: UInt64,
        compressedPages: UInt64,
        pageSize: UInt64
    ) -> UInt64 {
        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        return (appPages + wiredPages + compressedPages) * pageSize
    }

    private struct SwapUsage {
        var total: UInt64 = 0
        var available: UInt64 = 0
        var used: UInt64 = 0
        var pageSize: UInt32 = 0
        var encrypted: UInt32 = 0
    }

    private func readSwapUsage() -> SwapUsage {
        var usage = SwapUsage()
        var size = MemoryLayout<SwapUsage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        return result == 0 ? usage : SwapUsage()
    }

    private func readPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .unknown
        }
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }
}
