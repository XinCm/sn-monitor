import Foundation
import SNMonitorCore

// snctl — command line probe for sn-monitor.
//
//   snctl                     one JSON snapshot
//   snctl --watch             human readable line once per interval
//   snctl --watch --json      JSON line once per interval
//   snctl --interval 0.5      sampling interval in seconds (default 1)
//   snctl --count 5           stop after N samples (0 = forever)

struct Options {
    var watch = false
    var json = true
    var interval: TimeInterval = 1.0
    var count = 0
}

func parseOptions() -> Options {
    var options = Options()
    var index = 1
    let arguments = CommandLine.arguments
    while index < arguments.count {
        switch arguments[index] {
        case "--watch", "-w":
            options.watch = true
        case "--json", "-j":
            options.json = true
        case "--text":
            options.json = false
        case "--interval", "-i":
            index += 1
            if index < arguments.count, let value = Double(arguments[index]), value > 0 {
                options.interval = value
            }
        case "--count", "-n":
            index += 1
            if index < arguments.count, let value = Int(arguments[index]) {
                options.count = max(0, value)
            }
        case "--timing":
            break
        case "--help", "-h":
            print("""
            usage: snctl [--watch] [--json|--text] [--interval seconds] [--count n]

              (no flags)      print one JSON snapshot and exit
              --watch, -w     keep sampling
              --json, -j      JSON output (default for one-shot)
              --text          human readable output
              --interval, -i  seconds between samples (default 1)
              --count, -n     stop after n samples; 0 means unlimited
            """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown option: \(arguments[index])\n".utf8))
            exit(2)
        }
        index += 1
    }
    return options
}

let options = parseOptions()

if CommandLine.arguments.contains("--timing") {
    let cpu = CPUSampler()
    let memory = MemorySampler()
    let disk = DiskSampler()
    let display = DisplaySampler()
    let thermal = ThermalSampler()

    func measure(_ name: String, _ iterations: Int, _ body: () -> Void) {
        body()
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { body() }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        let padded = name.padding(toLength: 8, withPad: " ", startingAt: 0)
        print(String(format: "%@ %8.1f us/op", padded, elapsed / Double(iterations) * 1_000_000))
    }

    measure("cpu", 1000) { _ = cpu.sample() }
    measure("memory", 1000) { _ = memory.sample() }
    measure("disk", 1000) { _ = disk.sample() }
    measure("display", 1000) { _ = display.sample() }
    measure("thermal", 20) { _ = thermal.sample() }
    exit(0)
}

let collector = MetricsCollector()
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
encoder.dateEncodingStrategy = .iso8601

func jsonString(_ snapshot: Snapshot) -> String {
    guard let data = try? encoder.encode(snapshot),
          let string = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return string
}

func textLine(_ snapshot: Snapshot) -> String {
    let cpu = snapshot.cpu
    let memory = snapshot.memory
    let disk = snapshot.disk
    let display = snapshot.display
    let thermal = snapshot.thermal

    let cpuPart = String(
        format: "CPU %3.0f%% (u %2.0f s %2.0f)  load %.2f",
        cpu.usage * 100, cpu.user * 100, cpu.system * 100, cpu.loadAverage1
    )
    let memoryPart = String(
        format: "MEM %3.0f%% (%@ / %@, swap %@, %@)",
        memory.usage * 100,
        Format.bytes(memory.used), Format.bytes(memory.total),
        Format.bytes(memory.swapUsed), memory.pressure.label
    )
    let diskPart = String(
        format: "DISK r %@ w %@ (%@ free)",
        Format.rate(disk.readBytesPerSecond),
        Format.rate(disk.writeBytesPerSecond),
        Format.diskBytes(disk.free)
    )
    let displayPart = String(
        format: "DISP %.0f Hz %dx%d",
        display.refreshRate, display.pixelWidth, display.pixelHeight
    )
    let thermalPart = "TEMP cpu \(Format.temperature(thermal.cpuCelsius))"
        + " gpu \(Format.temperature(thermal.gpuCelsius))"
        + " batt \(Format.temperature(thermal.batteryCelsius))"

    return [cpuPart, memoryPart, diskPart, displayPart, thermalPart].joined(separator: "  ")
}

// Prime CPU / disk deltas before the first reported sample.
_ = collector.sample()
Thread.sleep(forTimeInterval: min(0.3, options.interval))

var emitted = 0
while true {
    let snapshot = collector.sample()
    if options.watch {
        print(options.json ? jsonString(snapshot) : textLine(snapshot))
    } else {
        print(options.json ? jsonString(snapshot) : textLine(snapshot))
    }
    fflush(stdout)

    emitted += 1
    if options.count > 0 && emitted >= options.count { break }
    if !options.watch { break }
    Thread.sleep(forTimeInterval: options.interval)
}
