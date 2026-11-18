import Foundation

// MARK: - CPU

public struct CPUSnapshot: Codable, Sendable {
    /// 0.0 ... 1.0
    public var usage: Double
    public var user: Double
    public var system: Double
    public var idle: Double
    public var loadAverage1: Double
    public var loadAverage5: Double
    public var loadAverage15: Double
    public var coreCount: Int

    public static let zero = CPUSnapshot(
        usage: 0, user: 0, system: 0, idle: 1,
        loadAverage1: 0, loadAverage5: 0, loadAverage15: 0,
        coreCount: ProcessInfo.processInfo.processorCount
    )
}

// MARK: - Memory

public enum MemoryPressure: String, Codable, Sendable {
    case normal
    case warning
    case critical
    case unknown

    public var label: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "偏高"
        case .critical: return "紧张"
        case .unknown: return "未知"
        }
    }
}

public struct MemorySnapshot: Codable, Sendable {
    public var total: UInt64
    public var used: UInt64
    public var cached: UInt64
    public var free: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: MemoryPressure

    public var usage: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(used) / Double(total))
    }

    public static let zero = MemorySnapshot(
        total: ProcessInfo.processInfo.physicalMemory,
        used: 0, cached: 0, free: 0,
        swapUsed: 0, swapTotal: 0, pressure: .unknown
    )
}

// MARK: - Disk

public struct DiskSnapshot: Codable, Sendable {
    public var total: UInt64
    public var free: UInt64
    public var readBytesPerSecond: Double
    public var writeBytesPerSecond: Double
    public var volumeName: String

    public var usage: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(total - min(total, free)) / Double(total))
    }

    public static let zero = DiskSnapshot(
        total: 0, free: 0,
        readBytesPerSecond: 0, writeBytesPerSecond: 0,
        volumeName: "Macintosh HD"
    )
}

// MARK: - Display

public struct DisplaySnapshot: Codable, Sendable {
    /// 0 when the panel reports no fixed refresh rate.
    public var refreshRate: Double
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var name: String

    public var isRetina: Bool { pixelWidth >= 2560 }

    public static let zero = DisplaySnapshot(
        refreshRate: 0, pixelWidth: 0, pixelHeight: 0, name: "显示器"
    )
}

// MARK: - Thermal

public struct ThermalSnapshot: Codable, Sendable {
    public var cpuCelsius: Double?
    public var gpuCelsius: Double?
    public var batteryCelsius: Double?
    public var availableKeys: [String]

    public var isAvailable: Bool {
        cpuCelsius != nil || gpuCelsius != nil || batteryCelsius != nil
    }

    public static let unavailable = ThermalSnapshot(
        cpuCelsius: nil, gpuCelsius: nil, batteryCelsius: nil, availableKeys: []
    )
}

// MARK: - Snapshot

public struct Snapshot: Codable, Sendable {
    public var timestamp: Date
    public var cpu: CPUSnapshot
    public var memory: MemorySnapshot
    public var disk: DiskSnapshot
    public var display: DisplaySnapshot
    public var thermal: ThermalSnapshot

    public static let zero = Snapshot(
        timestamp: Date(timeIntervalSince1970: 0),
        cpu: .zero, memory: .zero, disk: .zero,
        display: .zero, thermal: .unavailable
    )
}

// MARK: - Formatting helpers

public enum Format {
    public static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    public static func bytes(_ value: UInt64) -> String {
        bytes(Double(value))
    }

    public static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = max(0, value)
        var i = 0
        while v >= 1024 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        if i == 0 { return String(format: "%.0f %@", v, units[i]) }
        if v >= 100 { return String(format: "%.0f %@", v, units[i]) }
        return String(format: "%.1f %@", v, units[i])
    }

    /// Decimal units, matching Finder / `df -H` for storage.
    public static func diskBytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(value)
        var i = 0
        while v >= 1000 && i < units.count - 1 {
            v /= 1000
            i += 1
        }
        if i == 0 { return String(format: "%.0f %@", v, units[i]) }
        if v >= 100 { return String(format: "%.0f %@", v, units[i]) }
        return String(format: "%.1f %@", v, units[i])
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        bytes(bytesPerSecond) + "/s"
    }

    public static func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return "—" }
        return String(format: "%.1f°C", celsius)
    }
}
