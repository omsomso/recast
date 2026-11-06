import Foundation
import zlib

/// ID3v2.2–2.4 and ID3v1 reading; ID3v2.3/2.4 writing.
enum ID3 {
    // MARK: Reading

    /// Size of the ID3v2 tag at the start of `header` (10 bytes or more), including header and footer; nil when absent.
    static func tagSize(header: Data) -> Int? {
        guard header.count >= 10, header.hasPrefix("ID3") else { return nil }
        var reader = ByteReader(header, offset: 3)
        let major = reader.u8()
        _ = reader.u8()
        let flags = reader.u8()
        guard major >= 2, major <= 4 else { return nil }
        let size = syncsafe(reader.bytes(4))
        return 10 + size + (major == 4 && flags & 0x10 != 0 ? 10 : 0)
    }

    static func read(_ tag: Data) -> AudioTags {
        var tags = AudioTags()
        guard tag.count >= 10, tag.hasPrefix("ID3") else { return tags }
        var header = ByteReader(tag, offset: 3)
        let major = header.u8()
        _ = header.u8()
        let flags = header.u8()
        let size = syncsafe(header.bytes(4))
        guard major >= 2, major <= 4 else { return tags }
        var body = tag.subdata(in: (tag.startIndex + 10)..<(tag.startIndex + min(tag.count, 10 + size)))
        if flags & 0x80 != 0, major < 4 { body = unsynchronized(body) }
        var reader = ByteReader(body)
        if flags & 0x40 != 0, major >= 3 {
            let extended = reader.u32be()
            reader.offset = major == 4 ? syncsafe(UInt32(extended)) : 4 + Int(extended)
        }
        var pictures: [(type: UInt8, artwork: Artwork)] = []
        var dateParts: (year: String?, dayMonth: String?) = (nil, nil)

        while reader.remaining > (major == 2 ? 6 : 10) {
            let idLength = major == 2 ? 3 : 4
            let id = String(decoding: reader.bytes(idLength), as: UTF8.self)
            guard id.allSatisfy({ $0.isUppercase || $0.isNumber }), !id.isEmpty, id.first != "\u{0}" else { break }
            var frameSize: Int
            var formatFlags: UInt8 = 0
            if major == 2 {
                frameSize = Int(reader.u24be())
            } else {
                let raw = reader.u32be()
                frameSize = major == 4 ? syncsafe(raw) : Int(raw)
                // Some writers store plain sizes in v2.4; use them when the syncsafe size lands mid-frame.
                if major == 4, raw & 0x8080_8080 != 0 || !looksLikeFrame(body, at: reader.offset + 2 + frameSize), looksLikeFrame(body, at: reader.offset + 2 + Int(raw)) {
                    frameSize = Int(raw)
                }
                _ = reader.u8()
                formatFlags = reader.u8()
            }
            guard frameSize > 0, frameSize <= reader.remaining else { break }
            var payload = reader.bytes(frameSize)
            if major == 4 {
                if formatFlags & 0x40 != 0 { payload = payload.dropFirstData(1) }
                if formatFlags & 0x01 != 0 { payload = payload.dropFirstData(4) }
                if formatFlags & 0x02 != 0 || flags & 0x80 != 0 { payload = unsynchronized(payload) }
                if formatFlags & 0x04 != 0 { continue }
                if formatFlags & 0x08 != 0 { guard let inflated = inflate(payload) else { continue }; payload = inflated }
            } else if major == 3 {
                if formatFlags & 0x40 != 0 { continue }
                if formatFlags & 0x80 != 0 { guard let inflated = inflate(payload.dropFirstData(4)) else { continue }; payload = inflated }
                if formatFlags & 0x20 != 0 { payload = payload.dropFirstData(1) }
            }
            apply(id: canonical(id), payload: payload, major: major, to: &tags, pictures: &pictures, dateParts: &dateParts)
        }
        if tags.date == nil, let year = dateParts.year {
            if let dayMonth = dateParts.dayMonth, dayMonth.count == 4 {
                tags.date = "\(year)-\(dayMonth.suffix(2))-\(dayMonth.prefix(2))"
            } else {
                tags.date = year
            }
        }
        if let cover = pictures.first(where: { $0.type == 3 }) ?? pictures.first { tags.artwork = cover.artwork }
        return tags
    }

    /// ID3v1 from the last 128 bytes of a file.
    static func readV1(_ trailer: Data) -> AudioTags {
        var tags = AudioTags()
        guard trailer.count == 128, trailer.hasPrefix("TAG") else { return tags }
        func field(_ start: Int, _ length: Int) -> String? {
            let bytes = trailer.subdata(in: (trailer.startIndex + start)..<(trailer.startIndex + start + length))
            let trimmed = bytes.prefix { $0 != 0 }
            return AudioTags.clean(String(data: Data(trimmed), encoding: .isoLatin1))
        }
        tags.title = field(3, 30)
        tags.artist = field(33, 30)
        tags.album = field(63, 30)
        tags.date = field(93, 4)
        let base = trailer.startIndex
        if trailer[base + 125] == 0, trailer[base + 126] != 0 {
            tags.comment = field(97, 28)
            tags.track = Int(trailer[base + 126])
        } else {
            tags.comment = field(97, 30)
        }
        tags.genre = Genres.name(Int(trailer[base + 127]))
        return tags
    }

    private static func canonical(_ id: String) -> String {
        let v22: [String: String] = [
            "TT2": "TIT2", "TP1": "TPE1", "TAL": "TALB", "TP2": "TPE2", "TCM": "TCOM", "TCO": "TCON", "TYE": "TYER",
            "TDA": "TDAT", "TRK": "TRCK", "TPA": "TPOS", "COM": "COMM", "ULT": "USLT", "TCR": "TCOP", "TRC": "TSRC",
            "TT1": "TIT1", "TBP": "TBPM", "TCP": "TCMP", "TXX": "TXXX", "PIC": "PIC",
        ]
        return id.count == 3 ? (v22[id] ?? id) : id
    }

    private static func apply(id: String, payload: Data, major: UInt8, to tags: inout AudioTags,
                              pictures: inout [(type: UInt8, artwork: Artwork)], dateParts: inout (year: String?, dayMonth: String?)) {
        guard !payload.isEmpty else { return }
        let encoding = payload[payload.startIndex]
        let rest = payload.dropFirstData(1)
        func text() -> String? {
            let values = decodeStrings(rest, encoding: encoding).compactMap { AudioTags.clean($0) }
            return values.isEmpty ? nil : values.joined(separator: "; ")
        }
        func set(_ path: WritableKeyPath<AudioTags, String?>) { if tags[keyPath: path] == nil { tags[keyPath: path] = text() } }
        switch id {
        case "TIT2": set(\.title)
        case "TPE1": set(\.artist)
        case "TALB": set(\.album)
        case "TPE2": set(\.albumArtist)
        case "TCOM": set(\.composer)
        case "TCON":
            if tags.genre == nil, let value = text() { tags.genre = Genres.resolve(value) }
        case "TDRC": set(\.date)
        case "TYER": dateParts.year = text()
        case "TDAT": dateParts.dayMonth = text()
        case "TCOP": set(\.copyright)
        case "TSRC": set(\.isrc)
        case "GRP1": set(\.grouping)
        case "TIT1": set(\.grouping)
        case "TRCK":
            if let value = text() { let pair = AudioTags.numberPair(value); tags.track = tags.track ?? pair.0; tags.trackTotal = tags.trackTotal ?? pair.1 }
        case "TPOS":
            if let value = text() { let pair = AudioTags.numberPair(value); tags.disc = tags.disc ?? pair.0; tags.discTotal = tags.discTotal ?? pair.1 }
        case "TBPM": if tags.bpm == nil, let value = text() { tags.bpm = Int(Double(value)?.rounded() ?? 0).nonZero }
        case "TCMP": if let value = text() { tags.compilation = tags.compilation || value == "1" }
        case "COMM", "USLT":
            var reader = ByteReader(rest)
            reader.skip(3) // language
            let remainder = reader.bytes(reader.remaining)
            let (description, body) = splitTerminated(remainder, encoding: encoding)
            guard let value = AudioTags.clean(decodeStrings(body, encoding: encoding).joined(separator: "\n")) else { return }
            let label = AudioTags.clean(decodeString(description, encoding: encoding)) ?? ""
            if id == "USLT" {
                if tags.lyrics == nil { tags.lyrics = value }
            } else if label.isEmpty || label.lowercased() == "comment" || label.lowercased() == "description" {
                if tags.comment == nil { tags.comment = value }
            } else if !label.hasPrefix("iTun") {
                tags.set(vorbisName: label, value: value)
            }
        case "TXXX":
            let (description, body) = splitTerminated(rest, encoding: encoding)
            guard let label = AudioTags.clean(decodeString(description, encoding: encoding)),
                  let value = AudioTags.clean(decodeStrings(body, encoding: encoding).joined(separator: "; ")) else { return }
            tags.set(vorbisName: label, value: value)
        case "APIC":
            var reader = ByteReader(rest)
            var mimeBytes = Data()
            while !reader.isAtEnd { let byte = reader.u8(); if byte == 0 { break }; mimeBytes.append(byte) }
            let type = reader.u8()
            let (description, data) = splitTerminated(reader.bytes(reader.remaining), encoding: encoding)
            guard !data.isEmpty else { return }
            var mime = String(decoding: mimeBytes, as: UTF8.self).lowercased()
            if mime == "jpg" || mime == "image/jpg" { mime = "image/jpeg" }
            if mime == "png" { mime = "image/png" }
            pictures.append((type, Artwork(data: data, mimeType: mime.hasPrefix("image/") ? mime : nil,
                                           description: decodeString(description, encoding: encoding))))
        case "PIC":
            var reader = ByteReader(rest)
            let format = reader.fourCCPrefix(3).uppercased()
            let type = reader.u8()
            let (description, data) = splitTerminated(reader.bytes(reader.remaining), encoding: encoding)
            guard !data.isEmpty else { return }
            pictures.append((type, Artwork(data: data, mimeType: format == "PNG" ? "image/png" : format == "JPG" ? "image/jpeg" : nil,
                                           description: decodeString(description, encoding: encoding))))
        default:
            break
        }
    }

    private static func looksLikeFrame(_ body: Data, at offset: Int) -> Bool {
        if offset == body.count { return true }
        guard offset + 4 <= body.count else { return false }
        let bytes = body.subdata(in: (body.startIndex + offset)..<(body.startIndex + offset + 4))
        if bytes.allSatisfy({ $0 == 0 }) { return true }
        return bytes.allSatisfy { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) }
    }

    static func syncsafe(_ data: Data) -> Int {
        var reader = ByteReader(data)
        return syncsafe(reader.u32be())
    }

    static func syncsafe(_ value: UInt32) -> Int {
        Int((value & 0x7F) | ((value >> 8) & 0x7F) << 7 | ((value >> 16) & 0x7F) << 14 | ((value >> 24) & 0x7F) << 21)
    }

    private static func unsynchronized(_ data: Data) -> Data {
        var out = Data(capacity: data.count)
        var previous: UInt8 = 0
        for byte in data {
            if previous == 0xFF, byte == 0 { previous = 0; continue }
            out.append(byte)
            previous = byte
        }
        return out
    }

    private static func inflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data()
        var input = [UInt8](data)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var status: Int32 = Z_OK
        input.withUnsafeMutableBufferPointer { inputPointer in
            stream.next_in = inputPointer.baseAddress
            stream.avail_in = uInt(inputPointer.count)
            repeat {
                buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    output.append(out.baseAddress!, count: out.count - Int(stream.avail_out))
                }
            } while status == Z_OK
        }
        return status == Z_STREAM_END ? output : nil
    }

    /// Splits at the first terminator for the encoding (1 zero byte, or 2 aligned zero bytes for UTF-16).
    private static func splitTerminated(_ data: Data, encoding: UInt8) -> (Data, Data) {
        let bytes = [UInt8](data)
        if encoding == 1 || encoding == 2 {
            var index = 0
            while index + 1 < bytes.count {
                if bytes[index] == 0, bytes[index + 1] == 0 { return (Data(bytes[0..<index]), Data(bytes[(index + 2)...])) }
                index += 2
            }
        } else if let zero = bytes.firstIndex(of: 0) {
            return (Data(bytes[0..<zero]), Data(bytes[(zero + 1)...]))
        }
        return (data, Data())
    }

    private static func decodeStrings(_ data: Data, encoding: UInt8) -> [String] {
        var values: [String] = []
        var remaining = data
        while !remaining.isEmpty {
            let (head, tail) = splitTerminated(remaining, encoding: encoding)
            values.append(decodeString(head, encoding: encoding))
            if tail.count == 0 || tail.count == remaining.count { break }
            remaining = tail
        }
        return values
    }

    static func decodeString(_ data: Data, encoding: UInt8) -> String {
        switch encoding {
        case 1:
            if data.count >= 2 {
                let first = data[data.startIndex], second = data[data.startIndex + 1]
                if first == 0xFF, second == 0xFE { return String(data: data.dropFirstData(2), encoding: .utf16LittleEndian) ?? "" }
                if first == 0xFE, second == 0xFF { return String(data: data.dropFirstData(2), encoding: .utf16BigEndian) ?? "" }
            }
            return String(data: data, encoding: .utf16LittleEndian) ?? ""
        case 2: return String(data: data, encoding: .utf16BigEndian) ?? ""
        case 3: return String(decoding: data, as: UTF8.self)
        default: return String(data: data, encoding: .isoLatin1) ?? ""
        }
    }

    // MARK: Writing

    /// An ID3v2 tag. Version 4 writes UTF-8 text; version 3 writes UTF-16 for compatibility with older readers.
    static func makeTag(_ tags: AudioTags, version: UInt8, includeArtwork: Bool, padding: Int = 1024) -> Data {
        let encoding: UInt8 = version == 4 ? 3 : 1
        var frames = Data()
        func frame(_ id: String, _ payload: Data) {
            var writer = ByteWriter()
            writer.ascii(id)
            if version == 4 { writer.u32be(toSyncsafe(payload.count)) } else { writer.u32be(UInt32(payload.count)) }
            writer.u16be(0)
            writer.append(payload)
            frames.append(writer.data)
        }
        func textFrame(_ id: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            frame(id, Data([encoding]) + encode(value, encoding))
        }
        textFrame("TIT2", tags.title)
        textFrame("TPE1", tags.artist)
        textFrame("TALB", tags.album)
        textFrame("TPE2", tags.albumArtist)
        textFrame("TCOM", tags.composer)
        textFrame("TCON", tags.genre)
        if let date = tags.date {
            if version == 4 {
                textFrame("TDRC", date)
            } else {
                textFrame("TYER", String(date.prefix(4)))
                let parts = date.split(separator: "-")
                if parts.count == 3 { textFrame("TDAT", "\(parts[2])\(parts[1])") }
            }
        }
        if let track = tags.track { textFrame("TRCK", tags.trackTotal.map { "\(track)/\($0)" } ?? "\(track)") }
        if let disc = tags.disc { textFrame("TPOS", tags.discTotal.map { "\(disc)/\($0)" } ?? "\(disc)") }
        textFrame("TBPM", tags.bpm.map(String.init))
        if tags.compilation { textFrame("TCMP", "1") }
        textFrame("TCOP", tags.copyright)
        textFrame("TSRC", tags.isrc)
        textFrame("TIT1", tags.grouping)
        if let comment = tags.comment {
            frame("COMM", Data([encoding]) + Data("eng".utf8) + encode("", encoding) + terminator(encoding) + encode(comment, encoding))
        }
        if let lyrics = tags.lyrics {
            frame("USLT", Data([encoding]) + Data("eng".utf8) + encode("", encoding) + terminator(encoding) + encode(lyrics, encoding))
        }
        for key in tags.extra.keys.sorted() {
            frame("TXXX", Data([encoding]) + encode(key, encoding) + terminator(encoding) + encode(tags.extra[key]!, encoding))
        }
        if includeArtwork, let artwork = tags.artwork {
            frame("APIC", Data([encoding]) + Data(artwork.mimeType.utf8) + Data([0, 3]) + encode(artwork.description, encoding)
                  + terminator(encoding) + artwork.data)
        }
        var header = ByteWriter()
        header.ascii("ID3")
        header.u8(version)
        header.u8(0)
        header.u8(0)
        header.u32be(toSyncsafe(frames.count + padding))
        return header.data + frames + Data(count: padding)
    }

    static func toSyncsafe(_ value: Int) -> UInt32 {
        let v = UInt32(value)
        return (v & 0x7F) | ((v >> 7) & 0x7F) << 8 | ((v >> 14) & 0x7F) << 16 | ((v >> 21) & 0x7F) << 24
    }

    private static func encode(_ text: String, _ encoding: UInt8) -> Data {
        if encoding == 3 { return Data(text.utf8) }
        guard !text.isEmpty else { return Data([0xFF, 0xFE]) }
        return Data([0xFF, 0xFE]) + (text.data(using: .utf16LittleEndian) ?? Data())
    }

    private static func terminator(_ encoding: UInt8) -> Data { encoding == 1 || encoding == 2 ? Data([0, 0]) : Data([0]) }
}

extension Data {
    func dropFirstData(_ count: Int) -> Data {
        guard count < self.count else { return Data() }
        return subdata(in: (startIndex + count)..<endIndex)
    }
}

extension ByteReader {
    mutating func fourCCPrefix(_ count: Int) -> String { String(decoding: bytes(count), as: UTF8.self) }
}
