import Foundation

/// Synchronous, thread-confined collection of one system snapshot.
/// Create one instance per sampling thread; samplers remember deltas between calls.
public struct SamplerTimings: Sendable {
    public var cpu: TimeInterval = 0
    public var memory: TimeInterval = 0
    public var disk: TimeInterval = 0
    public var display: TimeInterval = 0
    public var thermal: TimeInterval = 0

    public init() {}
}

public final class MetricsCollector {
    private let cpuSampler = CPUSampler()
    private let memorySampler = MemorySampler()
    private let diskSampler = DiskSampler()
    private let displaySampler = DisplaySampler()
    private let thermalSampler = ThermalSampler()

    /// Last per-sampler durations, copied on the sampling thread.
    public private(set) var lastTimings = SamplerTimings()

    public init() {}

    /// Drops delta baselines so the next sample cannot report a spike after sleep.
    public func resetBaselines() {
        cpuSampler.reset()
        diskSampler.reset()
    }

    public func sample() -> Snapshot {
        func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

        var timings = SamplerTimings()

        var start = now()
        let cpu = cpuSampler.sample()
        timings.cpu = Double(now() - start) / 1_000_000_000

        start = now()
        let memory = memorySampler.sample()
        timings.memory = Double(now() - start) / 1_000_000_000

        start = now()
        let disk = diskSampler.sample()
        timings.disk = Double(now() - start) / 1_000_000_000

        start = now()
        let display = displaySampler.sample()
        timings.display = Double(now() - start) / 1_000_000_000

        start = now()
        let thermal = thermalSampler.sample()
        timings.thermal = Double(now() - start) / 1_000_000_000

        lastTimings = timings

        return Snapshot(
            timestamp: Date(),
            cpu: cpu,
            memory: memory,
            disk: disk,
            display: display,
            thermal: thermal
        )
    }
}
