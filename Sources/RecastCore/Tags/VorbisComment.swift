import Foundation
import ImageIO

/// Vorbis comments (FLAC, Ogg Vorbis, Opus) and FLAC picture blocks.
enum VorbisComment {
    /// Parses a comment block (vendor string, then the fields). `data` starts at the vendor length.
    static func read(_ data: Data) -> (tags: AudioTags, vendor: String) {
        var tags = AudioTags()
        var reader = ByteReader(data)
        let vendorLength = Int(reader.u32le())
        guard vendorLength <= reader.remaining else { return (tags, "") }
        let vendor = String(decoding: reader.bytes(vendorLength), as: UTF8.self)
        let count = Int(reader.u32le())
        var pictures: [(type: UInt32, artwork: Artwork)] = []
        for _ in 0..<min(count, 10_000) {
            let length = Int(reader.u32le())
            guard length <= reader.remaining else { break }
            let entry = String(decoding: reader.bytes(length), as: UTF8.self)
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let name = entry[..<equals].uppercased()
            let value = String(entry[entry.index(after: equals)...])
            switch name {
            case "METADATA_BLOCK_PICTURE":
                if let block = Data(base64Encoded: value, options: .ignoreUnknownCharacters), let picture = readPicture(block) { pictures.append(picture) }
            case "COVERART":
                if let image = Data(base64Encoded: value, options: .ignoreUnknownCharacters), !image.isEmpty { pictures.append((3, Artwork(data: image))) }
            case "COVERARTMIME":
                break
            default:
                if let existing = AudioTags.textFields.first(where: { $0.0 == name })?.1, let current = tags[keyPath: existing],
                   let addition = AudioTags.clean(value) {
                    tags[keyPath: existing] = current + "; " + addition // repeated fields, e.g. several artists
                } else {
                    tags.set(vorbisName: name, value: value)
                }
            }
        }
        if let cover = pictures.first(where: { $0.type == 3 }) ?? pictures.first { tags.artwork = cover.artwork }
        return (tags, vendor)
    }

    /// A comment block without the Vorbis framing bit. Artwork goes in as METADATA_BLOCK_PICTURE when asked
    /// (Ogg); FLAC stores it in its own picture block instead.
    static func make(_ tags: AudioTags, vendor: String, artworkField: Bool) -> Data {
        var fields = tags.vorbisFields().map { "\($0.0)=\($0.1)" }
        if artworkField, let artwork = tags.artwork {
            fields.append("METADATA_BLOCK_PICTURE=" + makePicture(artwork).base64EncodedString())
        }
        var writer = ByteWriter()
        let vendorBytes = Data(vendor.utf8)
        writer.u32le(UInt32(vendorBytes.count))
        writer.append(vendorBytes)
        writer.u32le(UInt32(fields.count))
        for field in fields {
            let bytes = Data(field.utf8)
            writer.u32le(UInt32(bytes.count))
            writer.append(bytes)
        }
        return writer.data
    }

    /// A FLAC PICTURE block body (also the payload of METADATA_BLOCK_PICTURE).
    static func makePicture(_ artwork: Artwork) -> Data {
        var width: UInt32 = 0, height: UInt32 = 0, depth: UInt32 = 24
        if let source = CGImageSourceCreateWithData(artwork.data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.uint32Value ?? 0
            height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.uint32Value ?? 0
            if (properties[kCGImagePropertyHasAlpha] as? Bool) == true { depth = 32 }
        }
        var writer = ByteWriter()
        writer.u32be(3) // front cover
        let mime = Data(artwork.mimeType.utf8)
        writer.u32be(UInt32(mime.count))
        writer.append(mime)
        let description = Data(artwork.description.utf8)
        writer.u32be(UInt32(description.count))
        writer.append(description)
        writer.u32be(width)
        writer.u32be(height)
        writer.u32be(depth)
        writer.u32be(0)
        writer.u32be(UInt32(artwork.data.count))
        writer.append(artwork.data)
        return writer.data
    }

    static func readPicture(_ data: Data) -> (type: UInt32, artwork: Artwork)? {
        var reader = ByteReader(data)
        let type = reader.u32be()
        let mimeLength = Int(reader.u32be())
        guard mimeLength <= reader.remaining else { return nil }
        let mime = String(decoding: reader.bytes(mimeLength), as: UTF8.self).lowercased()
        let descriptionLength = Int(reader.u32be())
        guard descriptionLength <= reader.remaining else { return nil }
        let description = String(decoding: reader.bytes(descriptionLength), as: UTF8.self)
        reader.skip(16)
        let length = Int(reader.u32be())
        guard length > 0, length <= reader.remaining else { return nil }
        let image = reader.bytes(length)
        return (type, Artwork(data: image, mimeType: mime.hasPrefix("image/") ? (mime == "image/jpg" ? "image/jpeg" : mime) : nil,
                              description: description))
    }
}

/// FLAC metadata blocks.
enum FLACTags {
    struct Block {
        var type: UInt8
        var body: Data
    }

    /// The metadata blocks and the offset of the first audio frame.
    static func blocks(of file: FileReader) -> (blocks: [Block], audioOffset: UInt64)? {
        var offset: UInt64 = 0
        let start = file.read(at: 0, count: 10)
        if let id3 = ID3.tagSize(header: start) { offset = UInt64(id3) }
        guard file.read(at: offset, count: 4).hasPrefix("fLaC") else { return nil }
        offset += 4
        var blocks: [Block] = []
        while offset + 4 <= file.size {
            var header = ByteReader(file.read(at: offset, count: 4))
            let flags = header.u8()
            let length = Int(header.u24be())
            offset += 4
            blocks.append(Block(type: flags & 0x7F, body: file.read(at: offset, count: length)))
            offset += UInt64(length)
            if flags & 0x80 != 0 { break }
        }
        return (blocks, offset)
    }

    static func read(_ file: FileReader) -> AudioTags {
        guard let (blocks, _) = blocks(of: file) else { return AudioTags() }
        var tags = AudioTags()
        var pictures: [(type: UInt32, artwork: Artwork)] = []
        for block in blocks {
            if block.type == 4 { tags.merge(VorbisComment.read(block.body).tags) }
            if block.type == 6, let picture = VorbisComment.readPicture(block.body) { pictures.append(picture) }
        }
        if tags.artwork == nil, let cover = pictures.first(where: { $0.type == 3 }) ?? pictures.first { tags.artwork = cover.artwork }
        return tags
    }

    /// Rewrites `url` with new comment and picture blocks; stream info, seek table and audio are kept as they are.
    static func write(_ tags: AudioTags, includeArtwork: Bool, to url: URL) throws {
        let file = try FileReader(url: url)
        guard let (blocks, audioOffset) = blocks(of: file) else { throw ConversionError.encoder("The FLAC file couldn't be read back.") }
        let vendor = blocks.first(where: { $0.type == 4 }).map { VorbisComment.read($0.body).vendor } ?? "Recast"
        var kept = blocks.filter { $0.type != 4 && $0.type != 6 && $0.type != 1 }
        kept.append(Block(type: 4, body: VorbisComment.make(tags, vendor: vendor, artworkField: false)))
        if includeArtwork, let artwork = tags.artwork { kept.append(Block(type: 6, body: VorbisComment.makePicture(artwork))) }
        kept.append(Block(type: 1, body: Data(count: 4096)))
        var header = Data("fLaC".utf8)
        for (index, block) in kept.enumerated() {
            var writer = ByteWriter()
            writer.u8(block.type | (index == kept.count - 1 ? 0x80 : 0))
            writer.u24be(UInt32(block.body.count))
            header.append(writer.data)
            header.append(block.body)
        }
        try replaceHead(of: url, keepingFrom: audioOffset, with: header)
    }
}

/// Writes `head` followed by the bytes of `url` from `offset` on, then replaces `url` with the result.
func replaceHead(of url: URL, keepingFrom offset: UInt64, with head: Data) throws {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    FileManager.default.createFile(atPath: temporary.path, contents: nil)
    do {
        let output = try FileHandle(forWritingTo: temporary)
        let input = try FileHandle(forReadingFrom: url)
        try output.write(contentsOf: head)
        try copyBytes(from: input, offset: offset, to: output)
        try output.close()
        try input.close()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } catch {
        try? FileManager.default.removeItem(at: temporary)
        throw error
    }
}

/// Reads the comment packet of an Ogg Vorbis or Opus stream.
enum OggTags {
    static func read(_ file: FileReader) -> AudioTags {
        var packets: [Data] = []
        var current = Data()
        var offset: UInt64 = 0
        var serial: UInt32?
        // Headers only: stop once the second packet is complete (artwork can make it span many pages).
        while packets.count < 2, offset + 27 <= file.size, current.count < 64 << 20 {
            var header = ByteReader(file.read(at: offset, count: 27))
            guard header.fourCC() == "OggS" else { break }
            header.skip(10) // version, type, granule
            let pageSerial = header.u32le()
            header.skip(8) // sequence, checksum
            let segmentCount = Int(header.u8())
            let lacing = [UInt8](file.read(at: offset + 27, count: segmentCount))
            var bodyOffset = offset + 27 + UInt64(segmentCount)
            let bodySize = lacing.reduce(0) { $0 + Int($1) }
            if serial == nil { serial = pageSerial }
            if pageSerial == serial {
                let body = file.read(at: bodyOffset, count: bodySize)
                var position = 0
                for value in lacing {
                    current.append(body.subdata(in: (body.startIndex + position)..<(body.startIndex + min(body.count, position + Int(value)))))
                    position += Int(value)
                    if value < 255 {
                        packets.append(current)
                        current = Data()
                        if packets.count == 2 { break }
                    }
                }
            }
            bodyOffset += UInt64(bodySize)
            offset = bodyOffset
        }
        guard packets.count == 2 else { return AudioTags() }
        let comment = packets[1]
        if comment.hasPrefix("\u{3}vorbis") { return VorbisComment.read(comment.dropFirstData(7)).tags }
        if comment.hasPrefix("OpusTags") { return VorbisComment.read(comment.dropFirstData(8)).tags }
        return AudioTags()
    }
}
