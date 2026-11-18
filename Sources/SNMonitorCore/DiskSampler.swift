import Foundation
import IOKit

/// Disk capacity plus physical read/write throughput.
///
/// Throughput comes from `IOBlockStorageDriver` statistics. APFS exposes several
/// virtual drivers (and mounted disk images look like disks too), so only drivers
/// backed by a whole physical media are kept; otherwise numbers would be counted
/// twice or more.
///
/// Not thread-safe: use from a single sampling queue.
public final class DiskSampler {
    private var drivers: [io_service_t] = []
    private var lastRead: UInt64 = 0
    private var lastWrite: UInt64 = 0
    private var lastTimestamp: Date?
    private var cachedCapacity: (total: UInt64, free: UInt64, name: String)?
    private var capacityTimestamp: Date?
    private static let capacityTTL: TimeInterval = 30

    public init() {
        drivers = Self.physicalDrivers()
    }

    deinit {
        for driver in drivers {
            IOObjectRelease(driver)
        }
    }

    public func reset() {
        lastTimestamp = nil
        capacityTimestamp = nil
    }

    public func sample() -> DiskSnapshot {
        if drivers.isEmpty {
            drivers = Self.physicalDrivers()
        }

        let counters = Self.readCounters(drivers)
        let now = Date()
        var readRate = 0.0
        var writeRate = 0.0

        if let lastTimestamp {
            let dt = now.timeIntervalSince(lastTimestamp)
            if dt > 0.001 {
                readRate = Self.rate(previous: lastRead, current: counters.read, dt: dt)
                writeRate = Self.rate(previous: lastWrite, current: counters.write, dt: dt)
            }
        }

        lastRead = counters.read
        lastWrite = counters.write
        lastTimestamp = now

        let capacity: (total: UInt64, free: UInt64, name: String)
        if let cached = cachedCapacity,
           let timestamp = capacityTimestamp,
           now.timeIntervalSince(timestamp) < Self.capacityTTL {
            capacity = cached
        } else {
            capacity = Self.volumeCapacity()
            cachedCapacity = capacity
            capacityTimestamp = now
        }

        return DiskSnapshot(
            total: capacity.total,
            free: capacity.free,
            readBytesPerSecond: readRate,
            writeBytesPerSecond: writeRate,
            volumeName: capacity.name
        )
    }

    static func rate(previous: UInt64, current: UInt64, dt: TimeInterval) -> Double {
        guard dt > 0, current >= previous else { return 0 }
        return Double(current - previous) / dt
    }

    // MARK: - IOKit

    private static func physicalDrivers() -> [io_service_t] {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOBlockStorageDriver")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var physical: [io_service_t] = []
        var all: [io_service_t] = []

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            all.append(service)
            if isPhysicalMedia(service) {
                physical.append(service)
            }
        }

        // Keep the retained services, release only the ones we drop.
        if !physical.isEmpty {
            for service in all where !physical.contains(service) {
                IOObjectRelease(service)
            }
            return physical
        }

        return all
    }

    private static func isPhysicalMedia(_ service: io_service_t) -> Bool {
        var child: io_registry_entry_t = 0
        guard IORegistryEntryGetChildEntry(service, kIOServicePlane, &child) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(child) }

        let whole = (property(child, "Whole") as? NSNumber)?.boolValue ?? false
        let product = (property(child, "Product Name") as? String) ?? ""
        return whole && !product.localizedCaseInsensitiveContains("Disk Image")
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func readCounters(_ drivers: [io_service_t]) -> (read: UInt64, write: UInt64) {
        var read: UInt64 = 0
        var write: UInt64 = 0
        for service in drivers {
            guard let statistics = property(service, "Statistics") as? [String: Any] else { continue }
            if let bytes = statistics["Bytes (Read)"] as? NSNumber {
                read &+= bytes.uint64Value
            }
            if let bytes = statistics["Bytes (Written)"] as? NSNumber {
                write &+= bytes.uint64Value
            }
        }
        return (read, write)
    }

    // MARK: - Capacity

    static func volumeCapacity() -> (total: UInt64, free: UInt64, name: String) {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeNameKey,
        ]
        if let values = try? url.resourceValues(forKeys: keys) {
            let total = UInt64(max(0, values.volumeTotalCapacity ?? 0))
            // `.volumeAvailableCapacityKey` matches Finder / df; the
            // "forImportantUsage" variant includes purgeable space and can
            // overstate what the user can actually store.
            var free = UInt64(max(0, values.volumeAvailableCapacity ?? 0))
            if free == 0 {
                free = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0))
            }
            if total > 0 {
                return (total, min(free, total), values.volumeName ?? "Macintosh HD")
            }
        }

        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/") {
            let total = (attributes[.systemSize] as? NSNumber)?.uint64Value ?? 0
            let free = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
            if total > 0 {
                return (total, min(free, total), "Macintosh HD")
            }
        }

        return (0, 0, "Macintosh HD")
    }
}
