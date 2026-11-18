import Foundation

/// Drives a `MetricsCollector` on a private serial queue and publishes snapshots
/// on the main queue.
public final class MetricsEngine {
    /// Called on the main queue for every sample.
    public var onSnapshot: ((Snapshot) -> Void)?

    public private(set) var interval: TimeInterval

    /// Diagnostics for `SNM_STATS`; not used by the UI.
    public private(set) var debugSampleCount = 0
    public private(set) var debugLastSampleDuration: TimeInterval = 0
    public var debugTimings: SamplerTimings { collector.lastTimings }

    private let queue = DispatchQueue(label: "com.sean.snmonitor.engine", qos: .userInitiated)
    private let collector = MetricsCollector()
    private var timer: DispatchSourceTimer?
    private var running = false

    public init(interval: TimeInterval = 1.0) {
        self.interval = max(0.2, interval)
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.collector.resetBaselines()
            _ = self.collector.sample() // establish CPU / disk deltas
            self.scheduleTimerLocked()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.timer?.cancel()
            self.timer = nil
        }
    }

    public func setInterval(_ newInterval: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            self.interval = max(0.2, newInterval)
            if self.running {
                self.scheduleTimerLocked()
            }
        }
    }

    /// Call after wake / unlock so deltas do not include the sleep period.
    public func resync() {
        queue.async { [weak self] in
            self?.collector.resetBaselines()
        }
    }

    private func scheduleTimerLocked() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(200)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let start = DispatchTime.now().uptimeNanoseconds
            let snapshot = self.collector.sample()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            self.debugSampleCount += 1
            self.debugLastSampleDuration = elapsed
            DispatchQueue.main.async {
                self.onSnapshot?(snapshot)
            }
        }
        source.resume()
        timer = source
    }
}
