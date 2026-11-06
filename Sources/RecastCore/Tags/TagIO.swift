import AudioToolbox
import Foundation

/// Reads tags from any supported audio file and writes them into Recast's outputs.
public enum TagIO {
    public static func read(_ url: URL) -> AudioTags {
        guard let file = try? FileReader(url: url) else { return AudioTags() }
        let head = file.read(at: 0, count: 64)
        var tags = AudioTags()
        if head.hasPrefix("fLaC") || (head.hasPrefix("ID3") && file.read(at: UInt64(ID3.tagSize(header: head) ?? 0), count: 4).hasPrefix("fLaC")) {
            tags = FLACTags.read(file)
        } else if head.hasPrefix("ID3") {
            let size = ID3.tagSize(header: head) ?? 0
            tags = ID3.read(file.read(at: 0, count: size))
            if file.size > 128 { tags.merge(ID3.readV1(file.read(at: file.size - 128, count: 128))) }
        } else if head.hasPrefix("OggS") {
            tags = OggTags.read(file)
        } else if head.hasPrefix("RIFF"), head.hasPrefix("WAVE", at: 8) {
            tags = ChunkTags.readWAV(file)
        } else if head.hasPrefix("FORM"), head.hasPrefix("AIFF", at: 8) || head.hasPrefix("AIFC", at: 8) {
            tags = ChunkTags.readAIFF(file)
        } else if head.hasPrefix("ftyp", at: 4) {
            tags = MP4Tags.read(file)
        } else if file.size > 128 {
            tags = ID3.readV1(file.read(at: file.size - 128, count: 128))
        }
        // Core Audio knows a few more containers (CAF, for one).
        if tags.isEmpty { tags = coreAudioTags(url) }
        return tags
    }

    static let infoKeys: [(String, WritableKeyPath<AudioTags, String?>)] = [
        (kAFInfoDictionary_Title, \.title), (kAFInfoDictionary_Artist, \.artist), (kAFInfoDictionary_Album, \.album),
        (kAFInfoDictionary_Composer, \.composer), (kAFInfoDictionary_Genre, \.genre), (kAFInfoDictionary_Year, \.date),
        (kAFInfoDictionary_Comments, \.comment), (kAFInfoDictionary_Copyright, \.copyright), (kAFInfoDictionary_ISRC, \.isrc),
    ]

    static func coreAudioTags(_ url: URL) -> AudioTags {
        var tags = AudioTags()
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else { return tags }
        defer { AudioFileClose(fileID) }
        var dictionary: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioFileGetProperty(fileID, kAudioFilePropertyInfoDictionary, &size, &dictionary) == noErr,
              let info = dictionary?.takeRetainedValue() as? [String: Any] else { return tags }
        for (key, path) in infoKeys { tags[keyPath: path] = AudioTags.clean(info[key] as? String) }
        if let track = info[kAFInfoDictionary_TrackNumber] as? String {
            let pair = AudioTags.numberPair(track)
            tags.track = pair.0
            tags.trackTotal = pair.1
        }
        if let tempo = info[kAFInfoDictionary_Tempo] as? String { tags.bpm = Int(Double(tempo)?.rounded() ?? 0).nonZero }
        return tags
    }

    static func coreAudioDictionary(_ tags: AudioTags) -> [String: String] {
        var info: [String: String] = [:]
        for (key, path) in infoKeys { if let value = tags[keyPath: path] { info[key] = value } }
        if let track = tags.track { info[kAFInfoDictionary_TrackNumber] = tags.trackTotal.map { "\(track)/\($0)" } ?? String(track) }
        if let bpm = tags.bpm { info[kAFInfoDictionary_Tempo] = String(bpm) }
        return info
    }

    /// Writes tags into a finished output whose encoder couldn't embed them while encoding.
    static func writeAfterEncoding(_ tags: AudioTags, includeArtwork: Bool, format: OutputFormat, to url: URL) throws {
        switch format {
        case .flac: try FLACTags.write(tags, includeArtwork: includeArtwork, to: url)
        case .aac, .alac: try MP4Tags.write(tags, includeArtwork: includeArtwork, to: url)
        case .wav: try ChunkTags.writeWAV(tags, includeArtwork: includeArtwork, to: url)
        case .aiff: try ChunkTags.writeAIFF(tags, includeArtwork: includeArtwork, to: url)
        case .caf, .mp3, .vorbis, .opus: break // written by the encoder
        }
    }
}

extension TagIO {
    /// Writes tags into an existing WAV, AIFF, FLAC or M4A file (other formats are written only while encoding).
    public static func write(_ tags: AudioTags, includeArtwork: Bool = true, to url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "wav", "wave": try ChunkTags.writeWAV(tags, includeArtwork: includeArtwork, to: url)
        case "aif", "aiff", "aifc": try ChunkTags.writeAIFF(tags, includeArtwork: includeArtwork, to: url)
        case "flac": try FLACTags.write(tags, includeArtwork: includeArtwork, to: url)
        case "m4a", "m4b", "mp4": try MP4Tags.write(tags, includeArtwork: includeArtwork, to: url)
        default: throw ConversionError.encoder("Recast can't add tags to .\(url.pathExtension) files after the fact.")
        }
    }
}
