import Foundation
import IOKit

/// Minimal AppleSMC client.
///
/// The SMC key ABI uses a fixed 80-byte structure. Field offsets below match the
/// kernel layout used by AppleSMC:
///
///     key            0..3
///     keyInfo.size   28..31
///     keyInfo.type   32..35
///     result         40
///     data8          42
///     data32         44..47
///     bytes          48..79
///
/// This is a private API. It needs no privileges, but it is not App Store material.
final class SMCClient {
    struct KeyInfo {
        let dataSize: UInt32
        let dataType: String
    }

    private static let kernelIndex: UInt32 = 2
    private static let readBytesCommand: UInt8 = 5
    private static let readKeyInfoCommand: UInt8 = 9
    private static let structureSize = 80

    private var connection: io_connect_t = 0

    var isOpen: Bool { connection != 0 }

    init?() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC"),
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let device = IOIteratorNext(iterator)
        guard device != 0 else { return nil }
        defer { IOObjectRelease(device) }

        var handle: io_connect_t = 0
        guard IOServiceOpen(device, mach_task_self_, 0, &handle) == KERN_SUCCESS else {
            return nil
        }
        connection = handle
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func readKey(_ key: String) -> (info: KeyInfo, bytes: [UInt8])? {
        guard let code = Self.fourCC(key) else { return nil }

        var input = [UInt8](repeating: 0, count: Self.structureSize)
        var output = [UInt8](repeating: 0, count: Self.structureSize)
        Self.writeU32(&input, 0, code)
        input[42] = Self.readKeyInfoCommand

        var outputSize = Self.structureSize
        var result = Self.call(connection, &input, &output, &outputSize)
        guard result == KERN_SUCCESS, output[40] == 0 else { return nil }

        let size = Self.readU32(output, 28)
        let type = Self.string(fromFourCC: Self.readU32(output, 32))
        guard size > 0, size <= 32 else { return nil }

        input = [UInt8](repeating: 0, count: Self.structureSize)
        Self.writeU32(&input, 0, code)
        Self.writeU32(&input, 28, size)
        input[42] = Self.readBytesCommand
        output = [UInt8](repeating: 0, count: Self.structureSize)
        outputSize = Self.structureSize

        result = Self.call(connection, &input, &output, &outputSize)
        guard result == KERN_SUCCESS, output[40] == 0 else { return nil }

        let bytes = Array(output[48..<(48 + Int(size))])
        return (KeyInfo(dataSize: size, dataType: type), bytes)
    }

    // MARK: - ABI helpers

    private static func call(
        _ connection: io_connect_t,
        _ input: inout [UInt8],
        _ output: inout [UInt8],
        _ outputSize: inout Int
    ) -> kern_return_t {
        var size = size_t(outputSize)
        let result: kern_return_t = input.withUnsafeBytes { inputPointer in
            output.withUnsafeMutableBytes { outputPointer in
                IOConnectCallStructMethod(
                    connection,
                    kernelIndex,
                    inputPointer.baseAddress,
                    structureSize,
                    outputPointer.baseAddress,
                    &size
                )
            }
        }
        outputSize = Int(size)
        return result
    }

    static func fourCC(_ key: String) -> UInt32? {
        let bytes = Array(key.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func string(fromFourCC code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    static func readU32(_ buffer: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(buffer[offset])
            | (UInt32(buffer[offset + 1]) << 8)
            | (UInt32(buffer[offset + 2]) << 16)
            | (UInt32(buffer[offset + 3]) << 24)
    }

    static func writeU32(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt32) {
        buffer[offset] = UInt8(value & 0xFF)
        buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
        buffer[offset + 2] = UInt8((value >> 16) & 0xFF)
        buffer[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    /// Decodes the common SMC data types. Returns nil for unsupported types.
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = readU32(bytes, 0)
            return Double(Float(bitPattern: bits))
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(raw) / 256.0
        case "ui8 ":
            guard let first = bytes.first else { return nil }
            return Double(first)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(
                (UInt32(bytes[0]) << 24)
                    | (UInt32(bytes[1]) << 16)
                    | (UInt32(bytes[2]) << 8)
                    | UInt32(bytes[3])
            )
        default:
            return nil
        }
    }
}
