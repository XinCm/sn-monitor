import Foundation

/// CPU / GPU / battery temperatures via AppleSMC.
///
/// Sensor key names differ between Intel and Apple silicon generations, and even
/// between M-series chips, so keys are probed once at startup instead of being
/// hard-coded. If nothing usable is found the snapshot stays empty and the UI
/// shows a dash.
public final class ThermalSampler {
    private let client: SMCClient?
    private var cpuKeys: [String] = []
    private var gpuKeys: [String] = []
    private var batteryKeys: [String] = []
    private var didProbe = false
    private var cachedSnapshot: ThermalSnapshot?
    private var lastRefresh: TimeInterval?

    private static let cpuCandidates = [
        "Tp00", "Tp04", "Tp05", "Tp09", "Tp0C", "Tp0D", "Tp0G", "Tp0O",
        "Tp0T", "Tp0X", "Tp0a", "Tp0p", "Tp0u", "Tp0y", "Tp12", "Tp16",
        "Tp1E", "Te04", "Te08", "Te0C", "Te0R",
        "TC0P", "TC0D", "TC0E", "TC0F",
    ]

    private static let gpuCandidates = [
        "Tg0C", "Tg04", "Tg0f", "Tg05", "Tg0U", "Tg1g", "Tg0X", "Tg1c",
    ]

    private static let batteryCandidates = ["TB0T", "TB1T", "TB2T"]

    public init() {
        client = SMCClient()
    }

    public func sample() -> ThermalSnapshot {
        // SMC reads are comparatively expensive and temperature moves slowly;
        // refresh at most every 2 seconds while the rest of the metrics stay at 1s.
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = cachedSnapshot,
           let last = lastRefresh,
           now - last < 2.0 {
            return cached
        }
        lastRefresh = now

        guard let client, client.isOpen else { return .unavailable }

        if !didProbe {
            didProbe = true
            cpuKeys = Self.probe(Self.cpuCandidates, client: client, limit: 4)
            gpuKeys = Self.probe(Self.gpuCandidates, client: client, limit: 2)
            batteryKeys = Self.probe(Self.batteryCandidates, client: client, limit: 1)
        }

        guard !cpuKeys.isEmpty || !gpuKeys.isEmpty || !batteryKeys.isEmpty else {
            return .unavailable
        }

        let snapshot = ThermalSnapshot(
            cpuCelsius: Self.maximumTemperature(cpuKeys, client: client),
            gpuCelsius: Self.maximumTemperature(gpuKeys, client: client),
            batteryCelsius: Self.maximumTemperature(batteryKeys, client: client),
            availableKeys: cpuKeys + gpuKeys + batteryKeys
        )
        cachedSnapshot = snapshot
        return snapshot
    }

    /// Reads every candidate once and keeps the hottest `limit` usable keys.
    /// Reading all SMC temperature keys every tick is surprisingly expensive;
    /// a handful of representative sensors is enough for a monitor.
    private static func probe(_ candidates: [String], client: SMCClient, limit: Int) -> [String] {
        var found: [(key: String, value: Double)] = []
        for key in candidates {
            guard let (info, bytes) = client.readKey(key),
                  let value = SMCClient.decode(type: info.dataType, bytes: bytes),
                  value > 0, value < 130 else {
                continue
            }
            found.append((key, value))
        }
        return found
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    private static func maximumTemperature(_ keys: [String], client: SMCClient) -> Double? {
        var maximum: Double?
        for key in keys {
            guard let (info, bytes) = client.readKey(key),
                  let value = SMCClient.decode(type: info.dataType, bytes: bytes),
                  value > 0, value < 130 else {
                continue
            }
            maximum = max(maximum ?? value, value)
        }
        return maximum
    }
}
