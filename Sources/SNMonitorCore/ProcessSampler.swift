import Foundation

/// One process entry for the details window.
public struct ProcessUsage: Sendable, Identifiable {
    public let pid: Int32
    public let name: String
    /// CPU usage in percent of one core (can exceed 100 for multithreaded processes).
    public let cpuPercent: Double
    /// Physical memory footprint in bytes.
    public let memoryBytes: UInt64

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, cpuPercent: Double, memoryBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

/// One complete `top` round.
public struct ProcessSample: Sendable {
    public let usages: [ProcessUsage]
    /// The first `top` round has no previous interval, so its CPU values are 0.
    public let cpuReady: Bool

    public init(usages: [ProcessUsage], cpuReady: Bool) {
        self.usages = usages
        self.cpuReady = cpuReady
    }
}

public enum ProcessSort: Sendable {
    case cpu
    case memory
}

/// Keeps a continuous `top` child alive while the details window is open.
///
/// `top -l 0 -s N -F -R -stats pid,cpu,mem` is setuid root, so root-owned
/// processes are included, and MEM is the process footprint. CPU comes from the
/// interval between adjacent rounds. Names are resolved from `ps` by PID.
public final class ProcessSampler {
    public var onSample: ((ProcessSample) -> Void)?
    public var onError: (() -> Void)?

    private let queue = DispatchQueue(label: "com.sean.snmonitor.process-reader", qos: .utility)
    private let stateLock = NSLock()
    private var process: Process?
    private var pipe: Pipe?
    private var buffer = ""
    private var rows: [(pid: Int32, cpu: Double, memory: UInt64)] = []
    private var blockIndex = -1
    private var started = false
    private var stopping = false
    private var reportedError = false

    public init() {}

    deinit {
        stop()
    }

    public func start(interval: TimeInterval) {
        stop()

        stateLock.lock()
        stopping = false
        reportedError = false
        stateLock.unlock()

        queue.sync {
            buffer = ""
            rows.removeAll()
            blockIndex = -1
            started = false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        let seconds = max(1, Int(interval.rounded()))
        process.arguments = [
            "-l", "0",
            "-s", "\(seconds)",
            "-F", "-R",
            "-stats", "pid,cpu,mem",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.stateLock.lock()
            let wasStopping = self.stopping
            self.stateLock.unlock()
            guard !wasStopping else { return }
            self.reportError()
        }

        do {
            try process.run()
        } catch {
            reportError()
            return
        }

        self.process = process
        self.pipe = pipe
        queue.async { [weak self] in
            self?.read(pipe.fileHandleForReading)
        }
    }

    public func stop() {
        stateLock.lock()
        stopping = true
        stateLock.unlock()

        pipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        pipe = nil
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

    // MARK: - Reading and parsing

    private func read(_ handle: FileHandle) {
        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            consume(data)
        }
    }

    private func consume(_ data: Data) {
        buffer += String(decoding: data, as: UTF8.self)
        while let newline = buffer.firstIndex(of: "\n") {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            handle(line)
        }
    }

    private func handle(_ line: Substring) {
        if line.hasPrefix("Processes:") {
            if started {
                emit()
            }
            started = true
            blockIndex += 1
            rows.removeAll()
            return
        }

        guard started, let row = Self.parseRow(line) else { return }
        rows.append(row)
    }

    private func emit() {
        let current = rows
        guard !current.isEmpty else { return }

        let topPID = process?.processIdentifier
        let names = psNames()
        let cpuReady = blockIndex > 0

        let usages = current
            .filter { $0.pid != topPID }
            .map { row -> ProcessUsage in
                let name = names[row.pid]
                    ?? (row.pid == 0 ? "kernel_task" : "PID \(row.pid)")
                return ProcessUsage(
                    pid: row.pid,
                    name: name,
                    cpuPercent: row.cpu,
                    memoryBytes: row.memory
                )
            }

        guard !usages.isEmpty else { return }
        let sample = ProcessSample(usages: usages, cpuReady: cpuReady)
        DispatchQueue.main.async { [weak self] in
            self?.onSample?(sample)
        }
    }

    private func psNames() -> [Int32: String] {
        guard let result = Self.run("/bin/ps", ["-Ao", "pid=,comm="]) else {
            return [:]
        }
        var names = Self.parsePSNames(result.output)
        names.removeValue(forKey: result.pid)
        return names
    }

    private func reportError() {
        stateLock.lock()
        if reportedError {
            stateLock.unlock()
            return
        }
        reportedError = true
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onError?()
        }
    }

    // MARK: - Parsers

    static func parseRow(_ line: Substring) -> (pid: Int32, cpu: Double, memory: UInt64)? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 3,
              let pid = Int32(fields[0]),
              pid >= 0,
              let cpu = Double(fields[1]),
              let memory = parseMemory(fields[2]) else {
            return nil
        }
        return (pid, cpu, memory)
    }

    /// Parses `ps -Ao pid=,comm=` output.
    static func parsePSNames(_ output: String) -> [Int32: String] {
        var names: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            let fields = line
                .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 2,
                  let pid = Int32(fields[0]),
                  pid >= 0 else {
                continue
            }
            let name = URL(fileURLWithPath: fields[1]).lastPathComponent
            names[pid] = name.isEmpty ? "PID \(pid)" : name
        }
        return names
    }

    static func parseMemory(_ text: Substring) -> UInt64? {
        var value = text
        while let last = value.last, last == "+" || last == "-" {
            value = value.dropLast()
        }
        guard let unit = value.last, let amount = Double(value.dropLast()) else {
            return nil
        }
        switch unit {
        case "K": return UInt64(amount * 1024)
        case "M": return UInt64(amount * 1024 * 1024)
        case "G": return UInt64(amount * 1024 * 1024 * 1024)
        case "B": return UInt64(amount)
        default: return nil
        }
    }

    private static func run(
        _ path: String,
        _ arguments: [String]
    ) -> (output: String, pid: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            return nil
        }

        let pid = process.processIdentifier
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return (String(decoding: data, as: UTF8.self), pid)
    }
}
