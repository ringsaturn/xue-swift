import Foundation

enum XueFormat {
    static let magic: [UInt8] = [0x58, 0x55, 0x45, 0, 0, 0, 0, 0]
    static let indexMagic: [UInt8] = [0x49, 0x44, 0x58, 0x31]
    static let headerSize = 80
    static let indexHeaderSize = 16
    static let entrySize = 40
    static let noDependency = UInt16.max
    static let checksumFlag: UInt8 = 1
    static let maxPlaneLength: UInt64 = 64 * 1024 * 1024
    /// The coarsest time-axis unit, and the only one schema versions 1 and 2
    /// can describe. A schemaVersion 3 axis names its own unit, which must
    /// divide it.
    static let hourSeconds = 3600
    /// The largest usable frame offset: 65535 is the dependencyOffset sentinel.
    static let maximumFrameOffset = UInt16.max - 1
    /// The metadata schema versions this decoder implements.
    static let schemaVersions = 1...3
}

struct ByteReader {
    let data: Data

    func bytes(at offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else {
            throw XueDecodeError("binary range exceeds available bytes")
        }
        return data.subdata(in: offset..<(offset + count))
    }

    func u8(_ offset: Int) throws -> UInt8 {
        guard offset >= 0, offset < data.count else { throw XueDecodeError("binary read exceeds available bytes") }
        return data[offset]
    }

    func u16(_ offset: Int) throws -> UInt16 {
        let b = try bytes(at: offset, count: 2)
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    func u32(_ offset: Int) throws -> UInt32 {
        let b = try bytes(at: offset, count: 4)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    func u64(_ offset: Int) throws -> UInt64 {
        let b = try bytes(at: offset, count: 8)
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(b[index]) << UInt64(index * 8) }
        return value
    }
}

func checkedAdd(_ left: UInt64, _ right: UInt64, label: String) throws -> UInt64 {
    let (result, overflow) = left.addingReportingOverflow(right)
    guard !overflow else { throw XueDecodeError("\(label) arithmetic overflow") }
    return result
}

func checkedMultiply(_ left: UInt64, _ right: UInt64, label: String) throws -> UInt64 {
    let (result, overflow) = left.multipliedReportingOverflow(by: right)
    guard !overflow else { throw XueDecodeError("\(label) arithmetic overflow") }
    return result
}

func align8(_ value: UInt64) throws -> UInt64 {
    try checkedAdd(value, 7, label: "offset") / 8 * 8
}

func checkedInt(_ value: UInt64, label: String) throws -> Int {
    guard value <= UInt64(Int.max) else { throw XueDecodeError("\(label) exceeds platform limits") }
    return Int(value)
}

func crc32(_ bytes: Data) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1)))
        }
    }
    return crc ^ 0xffff_ffff
}
