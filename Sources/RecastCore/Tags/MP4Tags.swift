import Foundation

/// iTunes-style tags in MP4/M4A files (moov/udta/meta/ilst).
enum MP4Tags {
    /// A parsed box. Containers keep children; everything else keeps its payload.
    final class Box {
        var type: String
        var payload: Data
        var children: [Box]?
        /// meta is a full box: four version/flag bytes come before its children.
        var prefix = Data()

        init(type: String, payload: Data = Data(), children: [Box]? = nil, prefix: Data = Data()) {
            self.type = type
            self.payload = payload
            self.children = children
            self.prefix = prefix
        }

        func child(_ type: String) -> Box? { children?.first { $0.type == type } }

        func serialized(chunkOffsetDelta delta: Int64 = 0) -> Data {
            var body = Data()
            if let children {
                body.append(prefix)
                for child in children { body.append(child.serialized(chunkOffsetDelta: delta)) }
            } else if delta != 0, type == "stco" || type == "co64" {
                body = MP4Tags.shiftChunkOffsets(payload, wide: type == "co64", by: delta)
            } else {
                body = payload
            }
            var writer = ByteWriter()
            let size = body.count + 8
            // Item names such as "\u{A9}nam" are single bytes (Latin-1), not UTF-8.
            let typeBytes = type.data(using: .isoLatin1) ?? Data(type.utf8)
            if size > Int(UInt32.max) {
                writer.u32be(1)
                writer.append(typeBytes)
                writer.u64be(UInt64(size + 8))
            } else {
                writer.u32be(UInt32(size))
                writer.append(typeBytes)
            }
            writer.append(body)
            return writer.data
        }
    }

    static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "udta", "edts", "dinf", "meta", "ilst"]

    static func parse(_ data: Data, container: String? = nil) -> [Box] {
        var boxes: [Box] = []
        var reader = ByteReader(data)
        while reader.remaining >= 8 {
            let start = reader.offset
            var size = Int(reader.u32be())
            let typeBytes = reader.bytes(4)
            let type = String(data: typeBytes, encoding: .isoLatin1) ?? "????"
            var header = 8
            if size == 1 { size = Int(reader.u64be()); header = 16 }
            if size == 0 { size = data.count - start }
            guard size >= header, start + size <= data.count else { break }
            let payload = data.subdata(in: (data.startIndex + start + header)..<(data.startIndex + start + size))
            // Items inside ilst are containers of data/mean/name boxes.
            if container == "ilst" {
                boxes.append(Box(type: type, children: parse(payload)))
            } else if type == "meta" {
                boxes.append(Box(type: type, children: parse(payload.dropFirstData(4), container: "meta"), prefix: payload.prefix(4)))
            } else if containers.contains(type) {
                boxes.append(Box(type: type, children: parse(payload, container: type)))
            } else {
                boxes.append(Box(type: type, payload: payload))
            }
            reader.offset = start + size
        }
        return boxes
    }

    /// Top-level boxes of a file: type, offset and size, without reading payloads.
    static func topLevel(_ file: FileReader) -> [(type: String, offset: UInt64, size: UInt64)] {
        var result: [(String, UInt64, UInt64)] = []
        var offset: UInt64 = 0
        while offset + 8 <= file.size {
            var reader = ByteReader(file.read(at: offset, count: 16))
            var size = UInt64(reader.u32be())
            let type = String(data: reader.bytes(4), encoding: .isoLatin1) ?? "????"
            if size == 1 { size = reader.u64be() }
            if size == 0 { size = file.size - offset }
            guard size >= 8, offset + size <= file.size else { break }
            result.append((type, offset, size))
            offset += size
        }
        return result
    }

    static func read(_ file: FileReader) -> AudioTags {
        guard let moovEntry = topLevel(file).first(where: { $0.type == "moov" }), moovEntry.size < 512 << 20 else { return AudioTags() }
        let moovData = file.read(at: moovEntry.offset, count: Int(moovEntry.size))
        guard let moov = parse(moovData).first,
              let ilst = moov.child("udta")?.child("meta")?.child("ilst") else { return AudioTags() }
        return read(ilst: ilst)
    }

    static func read(ilst: Box) -> AudioTags {
        var tags = AudioTags()
        for item in ilst.children ?? [] {
            let dataBoxes = (item.children ?? []).filter { $0.type == "data" }
            guard let first = dataBoxes.first, first.payload.count >= 8 else { continue }
            var header = ByteReader(first.payload)
            let typeCode = header.u32be() & 0x00FF_FFFF
            let value = first.payload.dropFirstData(8)
            let text = AudioTags.clean(String(decoding: value, as: UTF8.self))
            func set(_ path: WritableKeyPath<AudioTags, String?>) { if tags[keyPath: path] == nil { tags[keyPath: path] = text } }
            switch item.type {
            case "\u{A9}nam": set(\.title)
            case "\u{A9}ART": set(\.artist)
            case "\u{A9}alb": set(\.album)
            case "aART": set(\.albumArtist)
            case "\u{A9}wrt": set(\.composer)
            case "\u{A9}gen": set(\.genre)
            case "gnre":
                var reader = ByteReader(value)
                if tags.genre == nil { tags.genre = Genres.name(Int(reader.u16be()) - 1) }
            case "\u{A9}day": set(\.date)
            case "\u{A9}cmt": set(\.comment)
            case "\u{A9}lyr": set(\.lyrics)
            case "cprt": set(\.copyright)
            case "\u{A9}grp": set(\.grouping)
            case "trkn", "disk":
                var reader = ByteReader(value)
                reader.skip(2)
                let number = Int(reader.u16be()).nonZero, total = Int(reader.u16be()).nonZero
                if item.type == "trkn" { tags.track = number; tags.trackTotal = total } else { tags.disc = number; tags.discTotal = total }
            case "tmpo":
                var reader = ByteReader(value)
                tags.bpm = Int(value.count >= 2 ? reader.u16be() : UInt16(reader.u8())).nonZero
            case "cpil":
                tags.compilation = value.first.map { $0 != 0 } ?? false
            case "covr":
                if tags.artwork == nil, !value.isEmpty {
                    tags.artwork = Artwork(data: value, mimeType: typeCode == 14 ? "image/png" : typeCode == 13 ? "image/jpeg" : nil)
                }
            case "----":
                guard let nameBox = item.child("name"), nameBox.payload.count > 4,
                      let value = text else { continue }
                let name = String(decoding: nameBox.payload.dropFirstData(4), as: UTF8.self)
                tags.set(vorbisName: name, value: value)
            default:
                break
            }
        }
        return tags
    }

    // MARK: Writing

    static func dataBox(_ type: UInt32, _ value: Data) -> Box {
        var writer = ByteWriter()
        writer.u32be(type)
        writer.u32be(0)
        writer.append(value)
        return Box(type: "data", payload: writer.data)
    }

    static func items(for tags: AudioTags, includeArtwork: Bool) -> [Box] {
        var items: [Box] = []
        func text(_ type: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            items.append(Box(type: type, children: [dataBox(1, Data(value.utf8))]))
        }
        text("\u{A9}nam", tags.title)
        text("\u{A9}ART", tags.artist)
        text("\u{A9}alb", tags.album)
        text("aART", tags.albumArtist)
        text("\u{A9}wrt", tags.composer)
        text("\u{A9}gen", tags.genre)
        text("\u{A9}day", tags.date)
        text("\u{A9}cmt", tags.comment)
        text("\u{A9}lyr", tags.lyrics)
        text("cprt", tags.copyright)
        text("\u{A9}grp", tags.grouping)
        func pair(_ type: String, _ number: Int?, _ total: Int?, trailing: Bool) {
            guard number != nil || total != nil else { return }
            var writer = ByteWriter()
            writer.u16be(0)
            writer.u16be(UInt16(clamping: number ?? 0))
            writer.u16be(UInt16(clamping: total ?? 0))
            if trailing { writer.u16be(0) }
            items.append(Box(type: type, children: [dataBox(0, writer.data)]))
        }
        pair("trkn", tags.track, tags.trackTotal, trailing: true)
        pair("disk", tags.disc, tags.discTotal, trailing: false)
        if let bpm = tags.bpm {
            var writer = ByteWriter()
            writer.u16be(UInt16(clamping: bpm))
            items.append(Box(type: "tmpo", children: [dataBox(21, writer.data)]))
        }
        if tags.compilation { items.append(Box(type: "cpil", children: [dataBox(21, Data([1]))])) }
        var freeform = tags.extra
        if let isrc = tags.isrc { freeform["ISRC"] = isrc }
        for key in freeform.keys.sorted() {
            let mean = Box(type: "mean", payload: Data(count: 4) + Data("com.apple.iTunes".utf8))
            let name = Box(type: "name", payload: Data(count: 4) + Data(key.utf8))
            items.append(Box(type: "----", children: [mean, name, dataBox(1, Data(freeform[key]!.utf8))]))
        }
        if includeArtwork, let artwork = tags.artwork {
            items.append(Box(type: "covr", children: [dataBox(artwork.isPNG ? 14 : 13, artwork.data)]))
        }
        return items
    }

    /// Replaces the tags of an M4A file written by Core Audio. Encoder items (gapless info, encoder name) are kept;
    /// chunk offsets are shifted when the audio data has to move.
    static func write(_ tags: AudioTags, includeArtwork: Bool, to url: URL) throws {
        let file = try FileReader(url: url)
        let boxes = topLevel(file)
        guard let moovIndex = boxes.firstIndex(where: { $0.type == "moov" }) else { throw ConversionError.encoder("The M4A file has no movie box.") }
        let moovEntry = boxes[moovIndex]
        guard let moov = parse(file.read(at: moovEntry.offset, count: Int(moovEntry.size))).first else {
            throw ConversionError.encoder("The M4A movie box couldn't be read.")
        }
        let udta = moov.child("udta") ?? { let box = Box(type: "udta", children: []); moov.children?.append(box); return box }()
        let meta = udta.child("meta") ?? {
            var handler = ByteWriter()
            handler.u32be(0); handler.u32be(0); handler.ascii("mdir"); handler.ascii("appl"); handler.u32be(0); handler.u32be(0); handler.u16be(0)
            let box = Box(type: "meta", children: [Box(type: "hdlr", payload: handler.data)], prefix: Data(count: 4))
            udta.children?.append(box)
            return box
        }()
        let ilst = meta.child("ilst") ?? { let box = Box(type: "ilst", children: []); meta.children?.append(box); return box }()
        let encoderItems = (ilst.children ?? []).filter { item in
            if item.type == "\u{A9}too" { return true }
            guard item.type == "----", let name = item.child("name") else { return false }
            let label = String(decoding: name.payload.dropFirstData(4), as: UTF8.self)
            return label == "iTunSMPB" || label == "Encoding Params"
        }
        ilst.children = items(for: tags, includeArtwork: includeArtwork) + encoderItems

        let mdatOffset = boxes.first(where: { $0.type == "mdat" })?.offset ?? 0
        var head = Data()
        for box in boxes[..<moovIndex] { head.append(file.read(at: box.offset, count: Int(box.size))) }
        if mdatOffset > moovEntry.offset {
            // The audio follows the movie box: rewrite moov and the padding after it, shifting chunk offsets by the
            // change. Core Audio leaves about 60 KB of padding; 4 KB is plenty for later tag edits.
            let following = moovIndex + 1 < boxes.count ? boxes[moovIndex + 1] : nil
            let free = following?.type == "free" ? following : nil
            let oldSpan = Int64(moovEntry.size + (free?.size ?? 0))
            let padding: Int64 = 4096
            let delta = Int64(moov.serialized().count) + padding - oldSpan
            head.append(moov.serialized(chunkOffsetDelta: delta))
            var writer = ByteWriter()
            writer.u32be(UInt32(padding))
            writer.ascii("free")
            head.append(writer.data)
            head.append(Data(count: Int(padding) - 8))
            try replaceHead(of: url, keepingFrom: moovEntry.offset + UInt64(oldSpan), with: head)
        } else {
            head.append(moov.serialized())
            try replaceHead(of: url, keepingFrom: moovEntry.offset + moovEntry.size, with: head)
        }
    }

    static func shiftChunkOffsets(_ payload: Data, wide: Bool, by delta: Int64) -> Data {
        var reader = ByteReader(payload)
        var writer = ByteWriter()
        writer.u32be(reader.u32be()) // version and flags
        let count = reader.u32be()
        writer.u32be(count)
        for _ in 0..<count {
            if wide {
                writer.u64be(UInt64(Int64(reader.u64be()) + delta))
            } else {
                writer.u32be(UInt32(clamping: Int64(reader.u32be()) + delta))
            }
        }
        return writer.data
    }
}
