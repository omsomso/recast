import Foundation

/// The formats Recast writes.
public enum OutputFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case wav, aiff, flac, alac, caf, mp3, aac, vorbis, opus

    public var id: String { rawValue }

    public static let lossless: [OutputFormat] = [.wav, .aiff, .flac, .alac, .caf]
    public static let compressed: [OutputFormat] = [.mp3, .aac, .vorbis, .opus]

    public var title: String {
        switch self {
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .flac: return "FLAC"
        case .alac: return "Apple Lossless"
        case .caf: return "CAF"
        case .mp3: return "MP3"
        case .aac: return "AAC"
        case .vorbis: return "Ogg Vorbis"
        case .opus: return "Opus"
        }
    }

    /// One line for menus.
    public var summary: String {
        switch self {
        case .wav: return "Uncompressed. Plays everywhere."
        case .aiff: return "Uncompressed. The classic Mac format."
        case .flac: return "Lossless, about half the size of WAV."
        case .alac: return "Lossless, for Apple Music and iPhone."
        case .caf: return "Uncompressed Core Audio file, no size limit."
        case .mp3: return "Compressed. Plays everywhere."
        case .aac: return "Compressed. Better than MP3 at the same size."
        case .vorbis: return "Open compressed format, used by games."
        case .opus: return "The best quality at low bit rates."
        }
    }

    public var symbol: String {
        isLossless ? "waveform" : "waveform.badge.minus"
    }

    public var fileExtension: String {
        switch self {
        case .wav: return "wav"
        case .aiff: return "aiff"
        case .flac: return "flac"
        case .alac: return "m4a"
        case .caf: return "caf"
        case .mp3: return "mp3"
        case .aac: return "m4a"
        case .vorbis: return "ogg"
        case .opus: return "opus"
        }
    }

    public var isLossless: Bool { OutputFormat.lossless.contains(self) }

    /// Uncompressed PCM containers, which offer float and 32-bit sample formats.
    public var isPCM: Bool { self == .wav || self == .aiff || self == .caf }

    public var maxChannels: Int {
        switch self {
        case .mp3, .opus, .aac: return 2
        case .vorbis, .flac, .alac: return 8
        case .wav, .aiff, .caf: return 32
        }
    }

    /// Sample rates the encoder accepts; nil when any common rate works.
    public var sampleRates: [Double]? {
        switch self {
        case .mp3, .aac: return [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
        case .vorbis: return [8000, 11025, 16000, 22050, 32000, 44100, 48000]
        case .opus: return [48000]
        case .wav, .aiff, .caf, .flac, .alac: return nil
        }
    }

    /// The bit depths offered for this format (`.match` keeps the source's).
    public var bitDepths: [BitDepth] {
        switch self {
        case .wav, .aiff, .caf: return [.match, .int16, .int24, .int32, .float32]
        case .flac: return [.match, .int16, .int24]
        case .alac: return [.match, .int16, .int24, .int32]
        case .mp3, .aac, .vorbis, .opus: return []
        }
    }

    /// The rate this format will use for a wanted rate: the rate itself when allowed, otherwise the closest allowed
    /// rate of the same family (44.1 kHz or 48 kHz multiples), never above the highest allowed.
    public func supportedRate(for wanted: Double) -> Double {
        guard let rates = sampleRates, !rates.isEmpty else { return min(max(wanted, 8000), 384_000) }
        if rates.contains(wanted) { return wanted }
        let family: Double? = wanted.truncatingRemainder(dividingBy: 11025) == 0 ? 11025
            : wanted.truncatingRemainder(dividingBy: 8000) == 0 ? 8000 : nil
        let candidates = family.map { base in rates.filter { $0.truncatingRemainder(dividingBy: base) == 0 } } ?? rates
        let pool = candidates.isEmpty ? rates : candidates
        let below = pool.filter { $0 <= wanted }
        return below.max() ?? pool.min()!
    }
}

public enum BitDepth: String, Codable, CaseIterable, Identifiable, Sendable {
    case match, int16, int24, int32, float32
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .match: return "Same as source"
        case .int16: return "16-bit"
        case .int24: return "24-bit"
        case .int32: return "32-bit"
        case .float32: return "32-bit float"
        }
    }

    public var bits: Int? {
        switch self {
        case .match: return nil
        case .int16: return 16
        case .int24: return 24
        case .int32: return 32
        case .float32: return 32
        }
    }
}

public enum ChannelMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case keep, mono, stereo
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .keep: return "Same as source"
        case .mono: return "Mono"
        case .stereo: return "Stereo"
        }
    }
}

public enum VolumeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, loudness, peak, gain
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "Leave as is"
        case .loudness: return "Match loudness"
        case .peak: return "Normalize peaks"
        case .gain: return "Change by"
        }
    }
}

public enum Destination: String, Codable, Sendable {
    case nextToOriginal, folder
}

public enum CollisionPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case keepBoth, replace, skip
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .keepBoth: return "Keep both"
        case .replace: return "Replace"
        case .skip: return "Skip"
        }
    }
}

public enum MP3Mode: String, Codable, CaseIterable, Identifiable, Sendable {
    case cbr, vbr, abr
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cbr: return "Constant bit rate"
        case .vbr: return "Variable bit rate"
        case .abr: return "Average bit rate"
        }
    }
}

public enum AACMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case constrainedVBR, vbr, abr, cbr
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .constrainedVBR: return "Constrained variable"
        case .vbr: return "Variable (quality)"
        case .abr: return "Average bit rate"
        case .cbr: return "Constant bit rate"
        }
    }
}

public enum AACProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case lc, he
    public var id: String { rawValue }
    public var title: String { self == .lc ? "AAC-LC" : "HE-AAC" }
}

public enum VorbisMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case quality, bitrate
    public var id: String { rawValue }
    public var title: String { self == .quality ? "Quality" : "Average bit rate" }
}

/// Every choice that shapes one conversion. Stored as JSON; unknown or missing keys fall back to the defaults.
public struct ConversionSettings: Codable, Equatable, Sendable {
    public var format: OutputFormat = .mp3

    // Lossless and PCM
    public var pcmDepth: BitDepth = .match
    public var flacDepth: BitDepth = .match
    public var flacFast = false
    public var alacDepth: BitDepth = .match

    // MP3 (LAME)
    public var mp3Mode: MP3Mode = .cbr
    public var mp3Bitrate = 320
    public var mp3VBRQuality = 0
    public var mp3JointStereo = true

    // AAC (Core Audio)
    public var aacMode: AACMode = .constrainedVBR
    public var aacBitrate = 256
    /// 0 (smallest) to 127 (best); used by the variable (quality) mode.
    public var aacVBRQuality = 109
    public var aacProfile: AACProfile = .lc

    // Ogg Vorbis
    public var vorbisMode: VorbisMode = .quality
    public var vorbisQuality: Double = 6
    public var vorbisBitrate = 192

    // Opus
    public var opusBitrate = 160

    // Audio
    /// nil keeps the source's rate (or the nearest the format allows).
    public var sampleRate: Double? = nil
    public var channels: ChannelMode = .keep
    /// Dither when reducing to 16 or 24 bits (only when the samples actually change).
    public var dither = true
    public var noiseShaping = false

    // Volume
    public var volume: VolumeMode = .none
    public var loudnessTarget = -14.0
    public var truePeakCeiling = -1.0
    public var peakTarget = -1.0
    public var gainDB = 0.0

    // Metadata
    public var copyTags = true
    public var copyArtwork = true
    public var keepFileDates = false

    // Output
    public var destination: Destination = .nextToOriginal
    public var folderPath: String? = nil
    public var keepFolderStructure = true
    public var collision: CollisionPolicy = .keepBoth
    public var namePattern = "{name}"

    public init() {}

    /// Decodes stored settings, keeping defaults for anything missing or unreadable.
    public static func decode(_ data: Data) -> ConversionSettings {
        let defaults = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(ConversionSettings()))) as? [String: Any] ?? [:]
        let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        func decoded(_ object: [String: Any]) -> ConversionSettings? {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? JSONDecoder().decode(ConversionSettings.self, from: data)
        }
        // Keep each stored value that decodes on its own; a single bad value doesn't lose the rest.
        var good = defaults
        // Optional settings that are nil by default don't appear in the encoded defaults, so check property names.
        let known = Set(Mirror(reflecting: ConversionSettings()).children.compactMap(\.label))
        for (key, value) in stored where known.contains(key) {
            var attempt = good
            attempt[key] = value
            if decoded(attempt) != nil { good = attempt }
        }
        return decoded(good) ?? ConversionSettings()
    }

    /// The fields a preset stores: everything about the sound and tags, nothing about where files go.
    public func presetValue() -> ConversionSettings {
        var value = self
        let defaults = ConversionSettings()
        value.destination = defaults.destination
        value.folderPath = defaults.folderPath
        value.keepFolderStructure = defaults.keepFolderStructure
        value.collision = defaults.collision
        value.namePattern = defaults.namePattern
        return value
    }

    /// Applies a preset, keeping this settings' output location.
    public func applying(preset: ConversionSettings) -> ConversionSettings {
        var value = preset
        value.destination = destination
        value.folderPath = folderPath
        value.keepFolderStructure = keepFolderStructure
        value.collision = collision
        value.namePattern = namePattern
        return value
    }

    public var selectedDepth: BitDepth {
        switch format {
        case .wav, .aiff, .caf: return pcmDepth
        case .flac: return flacDepth
        case .alac: return alacDepth
        default: return .match
        }
    }

    public mutating func setDepth(_ depth: BitDepth) {
        switch format {
        case .wav, .aiff, .caf: pcmDepth = depth
        case .flac: flacDepth = depth
        case .alac: alacDepth = depth
        default: break
        }
    }
}

/// A named set of settings.
public struct Preset: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var settings: ConversionSettings
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, settings: ConversionSettings, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.settings = settings.presetValue()
        self.isBuiltIn = isBuiltIn
    }

    public static let builtIn: [Preset] = {
        func make(_ id: String, _ name: String, _ edit: (inout ConversionSettings) -> Void) -> Preset {
            var settings = ConversionSettings()
            edit(&settings)
            return Preset(id: UUID(uuidString: id)!, name: name, settings: settings, isBuiltIn: true)
        }
        return [
            make("6A1C1F00-0000-4000-8000-000000000001", "CD Quality (WAV, 16-bit, 44.1 kHz)") {
                $0.format = .wav; $0.pcmDepth = .int16; $0.sampleRate = 44100
            },
            make("6A1C1F00-0000-4000-8000-000000000002", "Studio (WAV, 24-bit, 48 kHz)") {
                $0.format = .wav; $0.pcmDepth = .int24; $0.sampleRate = 48000
            },
            make("6A1C1F00-0000-4000-8000-000000000003", "Archive (FLAC, original quality)") {
                $0.format = .flac; $0.flacDepth = .match
            },
            make("6A1C1F00-0000-4000-8000-000000000004", "Apple Music (AAC, 256 kbps)") {
                $0.format = .aac; $0.aacMode = .constrainedVBR; $0.aacBitrate = 256
            },
            make("6A1C1F00-0000-4000-8000-000000000005", "MP3, 320 kbps") {
                $0.format = .mp3; $0.mp3Mode = .cbr; $0.mp3Bitrate = 320
            },
            make("6A1C1F00-0000-4000-8000-000000000006", "Podcast (MP3, mono, −16 LUFS)") {
                $0.format = .mp3; $0.mp3Mode = .cbr; $0.mp3Bitrate = 96; $0.channels = .mono
                $0.volume = .loudness; $0.loudnessTarget = -16; $0.truePeakCeiling = -1
            },
            make("6A1C1F00-0000-4000-8000-000000000007", "Streaming (AAC, −14 LUFS)") {
                $0.format = .aac; $0.aacMode = .constrainedVBR; $0.aacBitrate = 256
                $0.volume = .loudness; $0.loudnessTarget = -14; $0.truePeakCeiling = -1
            },
            make("6A1C1F00-0000-4000-8000-000000000008", "Opus, 128 kbps") {
                $0.format = .opus; $0.opusBitrate = 128
            },
        ]
    }()
}
