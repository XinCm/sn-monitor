import Foundation
import SNMonitorCore

/// Rolling window of the last N samples for the panel sparklines.
final class HistoryStore {
    let capacity: Int
    private(set) var cpu: [Double] = []
    private(set) var memory: [Double] = []
    private(set) var disk: [Double] = []      // MB/s, read + write
    private(set) var refresh: [Double] = []
    private(set) var temperature: [Double] = [] // °C, only when available

    init(capacity: Int = 120) {
        self.capacity = capacity
    }

    func append(_ snapshot: Snapshot) {
        push(&cpu, snapshot.cpu.usage * 100)
        push(&memory, snapshot.memory.usage * 100)
        push(&disk, (snapshot.disk.readBytesPerSecond + snapshot.disk.writeBytesPerSecond) / 1_048_576)
        push(&refresh, snapshot.display.refreshRate)
        if let value = snapshot.thermal.cpuCelsius {
            push(&temperature, value)
        }
    }

    func clear() {
        cpu.removeAll()
        memory.removeAll()
        disk.removeAll()
        refresh.removeAll()
        temperature.removeAll()
    }

    private func push(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > capacity {
            array.removeFirst(array.count - capacity)
        }
    }
}
