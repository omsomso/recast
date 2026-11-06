import Foundation

/// Tags in WAV (RIFF LIST/INFO and id3 chunks) and AIFF (text and ID3 chunks) files.
enum ChunkTags {
    struct Chunk {
        var id: String
        var offset: UInt64 // of the chunk header
        var size: UInt64   // payload size
    }

    static func chunks(_ file: FileReader, bigEndian: Bool) -> [Chunk] {
        var chunks: [Chunk] = []
        var offset: UInt64 = 12
        while offset + 8 <= file.size {
            var reader = ByteReader(file.read(at: offset, count: 8))
            let id = reader.fourCC()
            let size = UInt64(bigEndian ? reader.u32be() : reader.u32le())
            chunks.append(Chunk(id: id, offset: offset, size: size))
            offset += 8 + size + (size & 1)
        }
        return chunks
    }

    static func readWAV(_ file: FileReader) -> AudioTags {
        var tags = AudioTags()
        let chunks = chunks(file, bigEndian: false)
        for chunk in chunks where chunk.id.lowercased() == "id3 " && chunk.size < 64 << 20 {
            tags.merge(ID3.read(file.read(at: chunk.offset + 8, count: Int(chunk.size))))
        }
        for chunk in chunks where chunk.id == "LIST" && chunk.size < 16 << 20 {
            let body = file.read(at: chunk.offset + 8, count: Int(chunk.size))
            guard body.hasPrefix("INFO") else { continue }
            var info = AudioTags()
            var reader = ByteReader(body, offset: 4)
            while reader.remaining >= 8 {
                let id = reader.fourCC()
                let size = Int(reader.u32le())
                let value = AudioTags.clean(decodeText(reader.bytes(size)))
                if size & 1 == 1 { reader.skip(1) }
                switch id {
                case "INAM": info.title = value
                case "IART": info.artist = value
                case "IPRD": info.album = value
                case "ICMT": info.comment = value
                case "ICRD": info.date = value
                case "IGNR": info.genre = value
                case "ICOP": info.copyright = value
                case "ITRK", "IPRT": info.track = value.flatMap { AudioTags.numberPair($0).0 }
                default: break
                }
            }
            tags.merge(info)
        }
        return tags
    }

    static func readAIFF(_ file: FileReader) -> AudioTags {
        var tags = AudioTags()
        let chunks = chunks(file, bigEndian: true)
        for chunk in chunks where chunk.id.uppercased() == "ID3 " && chunk.size < 64 << 20 {
            tags.merge(ID3.read(file.read(at: chunk.offset + 8, count: Int(chunk.size))))
        }
        var text = AudioTags()
        for chunk in chunks where chunk.size < 1 << 20 {
            let value = AudioTags.clean(decodeText(file.read(at: chunk.offset + 8, count: Int(chunk.size))))
            switch chunk.id {
            case "NAME": text.title = text.title ?? value
            case "AUTH": text.artist = text.artist ?? value
            case "(c) ": text.copyright = text.copyright ?? value
            case "ANNO": text.comment = text.comment ?? value
            default: break
            }
        }
        tags.merge(text)
        return tags
    }

    private static func decodeText(_ data: Data) -> String {
        let trimmed = Data(data.prefix { $0 != 0 })
        return String(data: trimmed, encoding: .utf8) ?? String(data: trimmed, encoding: .isoLatin1) ?? ""
    }

    // MARK: Writing

    /// Appends an INFO list and an ID3 chunk to a WAV file and fixes the RIFF size. RF64 files keep their size in
    /// the ds64 chunk, so they are left alone.
    static func writeWAV(_ tags: AudioTags, includeArtwork: Bool, to url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 12), header.hasPrefix("RIFF"), header.hasPrefix("WAVE", at: 8) else { return }
        var info = ByteWriter()
        info.ascii("INFO")
        func entry(_ id: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            var bytes = Data(value.utf8)
            bytes.append(0)
            info.ascii(id)
            info.u32le(UInt32(bytes.count))
            info.append(bytes)
            if bytes.count & 1 == 1 { info.u8(0) }
        }
        entry("INAM", tags.title)
        entry("IART", tags.artist)
        entry("IPRD", tags.album)
        entry("IGNR", tags.genre)
        entry("ICRD", tags.date)
        entry("ICMT", tags.comment)
        entry("ICOP", tags.copyright)
        entry("ITRK", tags.track.map(String.init))
        entry("ISFT", "Recast")
        var appended = ByteWriter()
        appended.ascii("LIST")
        appended.u32le(UInt32(info.data.count))
        appended.append(info.data)
        let id3 = ID3.makeTag(tags, version: 3, includeArtwork: includeArtwork, padding: 0)
        appended.ascii("id3 ")
        appended.u32le(UInt32(id3.count))
        appended.append(id3)
        if id3.count & 1 == 1 { appended.u8(0) }
        let end = try handle.seekToEnd()
        // RIFF chunks start on even offsets.
        var start = end
        if end & 1 == 1 { try handle.write(contentsOf: Data([0])); start += 1 }
        let total = start + UInt64(appended.data.count)
        guard total - 8 <= UInt64(UInt32.max) else { try handle.truncate(atOffset: end); return }
        try handle.write(contentsOf: appended.data)
        try handle.seek(toOffset: 4)
        var size = ByteWriter()
        size.u32le(UInt32(total - 8))
        try handle.write(contentsOf: size.data)
    }

    /// Appends name/author/copyright/annotation chunks and an ID3 chunk to an AIFF file and fixes the FORM size.
    static func writeAIFF(_ tags: AudioTags, includeArtwork: Bool, to url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 12), header.hasPrefix("FORM") else { return }
        var appended = ByteWriter()
        func chunk(_ id: String, _ payload: Data) {
            appended.ascii(id)
            appended.u32be(UInt32(payload.count))
            appended.append(payload)
            if payload.count & 1 == 1 { appended.u8(0) }
        }
        if let title = tags.title { chunk("NAME", Data(title.utf8)) }
        if let artist = tags.artist { chunk("AUTH", Data(artist.utf8)) }
        if let copyright = tags.copyright { chunk("(c) ", Data(copyright.utf8)) }
        if let comment = tags.comment { chunk("ANNO", Data(comment.utf8)) }
        chunk("ID3 ", ID3.makeTag(tags, version: 3, includeArtwork: includeArtwork, padding: 0))
        let end = try handle.seekToEnd()
        var start = end
        if end & 1 == 1 { try handle.write(contentsOf: Data([0])); start += 1 }
        let total = start + UInt64(appended.data.count)
        guard total - 8 <= UInt64(UInt32.max) else { try handle.truncate(atOffset: end); return }
        try handle.write(contentsOf: appended.data)
        try handle.seek(toOffset: 4)
        var size = ByteWriter()
        size.u32be(UInt32(total - 8))
        try handle.write(contentsOf: size.data)
    }
}
