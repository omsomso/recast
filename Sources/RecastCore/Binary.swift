import Foundation

/// Reads integers and strings from a byte buffer; reads past the end return zeros rather than trapping.
struct ByteReader {
    let data: Data
    var offset: Int

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var remaining: Int { max(0, data.count - offset) }
    var isAtEnd: Bool { offset >= data.count }

    func byte(at index: Int) -> UInt8 {
        guard index >= 0, index < data.count else { return 0 }
        return data[data.startIndex + index]
    }

    mutating func u8() -> UInt8 {
        defer { offset += 1 }
        return byte(at: offset)
    }

    mutating func u16be() -> UInt16 { UInt16(u8()) << 8 | UInt16(u8()) }
    mutating func u16le() -> UInt16 { let low = UInt16(u8()); return UInt16(u8()) << 8 | low }
    mutating func u24be() -> UInt32 { UInt32(u8()) << 16 | UInt32(u8()) << 8 | UInt32(u8()) }
    mutating func u32be() -> UInt32 { UInt32(u16be()) << 16 | UInt32(u16be()) }
    mutating func u32le() -> UInt32 { let low = UInt32(u16le()); return UInt32(u16le()) << 16 | low }
    mutating func u64be() -> UInt64 { UInt64(u32be()) << 32 | UInt64(u32be()) }

    mutating func bytes(_ count: Int) -> Data {
        let count = max(0, count)
        let start = min(offset, data.count), end = min(offset + count, data.count)
        offset += count
        return data.subdata(in: (data.startIndex + start)..<(data.startIndex + end))
    }

    mutating func fourCC() -> String {
        String(decoding: bytes(4), as: UTF8.self)
    }

    mutating func skip(_ count: Int) { offset += max(0, count) }
}

/// Builds byte buffers.
struct ByteWriter {
    var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16be(_ value: UInt16) { u8(UInt8(value >> 8)); u8(UInt8(value & 0xFF)) }
    mutating func u16le(_ value: UInt16) { u8(UInt8(value & 0xFF)); u8(UInt8(value >> 8)) }
    mutating func u24be(_ value: UInt32) { u8(UInt8((value >> 16) & 0xFF)); u8(UInt8((value >> 8) & 0xFF)); u8(UInt8(value & 0xFF)) }
    mutating func u32be(_ value: UInt32) { u16be(UInt16(value >> 16)); u16be(UInt16(value & 0xFFFF)) }
    mutating func u32le(_ value: UInt32) { u16le(UInt16(value & 0xFFFF)); u16le(UInt16(value >> 16)) }
    mutating func u64be(_ value: UInt64) { u32be(UInt32(value >> 32)); u32be(UInt32(value & 0xFFFF_FFFF)) }
    mutating func append(_ bytes: Data) { data.append(bytes) }
    mutating func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
}

/// Random access to a file without loading all of it.
final class FileReader {
    private let handle: FileHandle
    let size: UInt64

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    func read(at offset: UInt64, count: Int) -> Data {
        guard offset < size, count > 0 else { return Data() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: min(count, Int(size - offset))) ?? Data()
        } catch {
            return Data()
        }
    }
}

extension Data {
    func hasPrefix(_ text: String, at offset: Int = 0) -> Bool {
        let bytes = Array(text.utf8)
        guard count >= offset + bytes.count else { return false }
        for (index, byte) in bytes.enumerated() where self[startIndex + offset + index] != byte { return false }
        return true
    }
}

/// Copies `source` to `destination` in chunks, starting at `offset` (to the end, or `length` bytes).
func copyBytes(from source: FileHandle, offset: UInt64, length: UInt64? = nil, to destination: FileHandle) throws {
    try source.seek(toOffset: offset)
    var left = length ?? UInt64.max
    while left > 0 {
        let chunk = try source.read(upToCount: Int(Swift.min(left, 4 << 20))) ?? Data()
        if chunk.isEmpty { break }
        try destination.write(contentsOf: chunk)
        left -= UInt64(chunk.count)
    }
}
