import Testing
@testable import SNMonitorCore

@Suite("SMC")
struct SMCTests {
    @Test("FourCC encoding and decoding")
    func fourCC() {
        #expect(SMCClient.fourCC("Tp0C") == 0x5470_3043)
        #expect(SMCClient.string(fromFourCC: 0x5470_3043) == "Tp0C")
        #expect(SMCClient.fourCC("abc") == nil)
    }

    @Test("SMC data type decoding")
    func decoding() throws {
        let floatValue = try #require(
            SMCClient.decode(type: "flt ", bytes: [0x00, 0xA0, 0xC1, 0x41])
        )
        #expect(abs(floatValue - Double(Float(bitPattern: 0x41C1_A000))) < 0.0001)

        let sp78 = try #require(SMCClient.decode(type: "sp78", bytes: [0x19, 0x80]))
        #expect(abs(sp78 - 25.5) < 0.001)

        #expect(try #require(SMCClient.decode(type: "ui16", bytes: [0x01, 0x2C])) == 300)
        #expect(try #require(SMCClient.decode(type: "ui8 ", bytes: [0x2A])) == 42)
        #expect(try #require(SMCClient.decode(type: "ui32", bytes: [0x00, 0x00, 0x01, 0x00])) == 256)
        #expect(SMCClient.decode(type: "tfoi", bytes: [0, 0, 0, 0]) == nil)
    }
}

@Suite("Samplers")
struct SamplerTests {
    @Test("CPU tick counter wraps at 2^32")
    func cpuWrap() {
        #expect(CPUSampler.wrapDelta(5, 10) == UInt64(UInt32.max) + 1 - 10 + 5)
        #expect(CPUSampler.wrapDelta(10, 5) == 5)
    }

    @Test("Disk rates ignore resets and zero intervals")
    func diskRate() {
        #expect(DiskSampler.rate(previous: 1_000, current: 2_000, dt: 2) == 500)
        #expect(DiskSampler.rate(previous: 2_000, current: 1_000, dt: 2) == 0)
        #expect(DiskSampler.rate(previous: 1_000, current: 2_000, dt: 0) == 0)
    }

    @Test("Memory used = app + wired + compressed")
    func memoryMath() {
        let used = MemorySampler.usedBytes(
            internalPages: 100,
            purgeablePages: 10,
            wiredPages: 20,
            compressedPages: 30,
            pageSize: 16_384
        )
        #expect(used == 140 * 16_384)

        let empty = MemorySnapshot(
            total: 100, used: 0, cached: 0, free: 100,
            swapUsed: 0, swapTotal: 0, pressure: .normal
        )
        #expect(empty.usage == 0)

        let full = MemorySnapshot(
            total: 100, used: 120, cached: 0, free: 0,
            swapUsed: 0, swapTotal: 0, pressure: .critical
        )
        #expect(full.usage == 1)
    }
}

@Suite("Formatting")
struct FormattingTests {
    @Test("Percent, bytes, rates")
    func formatting() {
        #expect(Format.percent(0.126) == "13%")
        #expect(Format.bytes(UInt64(1_536)) == "1.5 KB")
        #expect(Format.bytes(UInt64(0)) == "0 B")
        #expect(Format.rate(1_048_576) == "1.0 MB/s")
        #expect(Format.diskBytes(684_591_751_168) == "685 GB")
        #expect(Format.diskBytes(UInt64(0)) == "0 B")
    }
}


@Suite("Processes")
struct ProcessTests {
    private func usage(_ name: String, cpu: Double, memory: UInt64) -> ProcessUsage {
        ProcessUsage(pid: 1, name: name, cpuPercent: cpu, memoryBytes: memory)
    }

    @Test("Top processes by CPU")
    func topByCPU() {
        let items = [
            usage("A", cpu: 5, memory: 300),
            usage("B", cpu: 30, memory: 100),
            usage("C", cpu: 12, memory: 200),
            usage("D", cpu: 30, memory: 50),
        ]
        let top = ProcessSampler.top(items, by: .cpu, limit: 3)
        #expect(top.map(\.name) == ["B", "D", "C"])
    }

    @Test("Top processes by memory")
    func topByMemory() {
        let items = [
            usage("A", cpu: 5, memory: 300),
            usage("B", cpu: 30, memory: 100),
            usage("C", cpu: 12, memory: 500),
        ]
        let top = ProcessSampler.top(items, by: .memory, limit: 2)
        #expect(top.map(\.name) == ["C", "A"])
    }

    @Test("Parses top rows including PID 0")
    func parseTopRow() throws {
        let row = try #require(ProcessSampler.parseRow("0      6.1   93M  "[...]))
        #expect(row.pid == 0)
        #expect(row.cpu == 6.1)
        #expect(row.memory == 93 * 1024 * 1024)
        #expect(ProcessSampler.parseRow("PID %CPU MEM"[...]) == nil)
    }

    @Test("Parses process names from ps")
    func parsePSNames() {
        let output = """
          1 /sbin/launchd
        521 /System/Library/Frameworks/CoreServices.framework/FSEvents.framework/Support/fseventsd
        590 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
        """
        let names = ProcessSampler.parsePSNames(output)
        #expect(names[1] == "launchd")
        #expect(names[521] == "fseventsd")
        #expect(names[590] == "WindowServer")
    }

    @Test("Parses top memory units")
    func memoryUnits() {
        #expect(ProcessSampler.parseMemory("512K") == 512 * 1024)
        #expect(ProcessSampler.parseMemory("93M") == 93 * 1024 * 1024)
        #expect(ProcessSampler.parseMemory("1G") == 1024 * 1024 * 1024)
        #expect(ProcessSampler.parseMemory("N/A") == nil)
    }
}
