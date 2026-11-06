import Foundation

/// A ready-made quality setting for one format, as offered in the quick menu.
public struct QualityChoice: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    let apply: @Sendable (inout ConversionSettings) -> Void
    let matches: @Sendable (ConversionSettings) -> Bool

    public func applied(to settings: ConversionSettings) -> ConversionSettings {
        var copy = settings
        apply(&copy)
        return copy
    }

    public func isSelected(in settings: ConversionSettings) -> Bool { matches(settings) }
}

extension OutputFormat {
    public var qualityChoices: [QualityChoice] {
        switch self {
        case .wav, .aiff, .caf:
            return [BitDepth.match, .int16, .int24, .float32].map { depth in
                QualityChoice(id: depth.rawValue, title: depth.title,
                              detail: depth == .match ? "Keeps each file's bit depth (24-bit for compressed sources)" : "",
                              apply: { $0.pcmDepth = depth }, matches: { $0.pcmDepth == depth })
            }
        case .flac:
            return [BitDepth.match, .int16, .int24].map { depth in
                QualityChoice(id: depth.rawValue, title: depth.title,
                              detail: depth == .match ? "Keeps each file's bit depth (24-bit for compressed sources)" : "",
                              apply: { $0.flacDepth = depth }, matches: { $0.flacDepth == depth })
            }
        case .alac:
            return [BitDepth.match, .int16, .int24].map { depth in
                QualityChoice(id: depth.rawValue, title: depth.title,
                              detail: depth == .match ? "Keeps each file's bit depth (24-bit for compressed sources)" : "",
                              apply: { $0.alacDepth = depth }, matches: { $0.alacDepth == depth })
            }
        case .mp3:
            let cbr = [320, 256, 192, 128].map { rate in
                QualityChoice(id: "cbr\(rate)", title: "\(rate) kbps", detail: rate == 320 ? "Highest quality" : "",
                              apply: { $0.mp3Mode = .cbr; $0.mp3Bitrate = rate },
                              matches: { $0.mp3Mode == .cbr && $0.mp3Bitrate == rate })
            }
            let vbr = [(0, "about 245 kbps"), (2, "about 190 kbps")].map { level, size in
                QualityChoice(id: "v\(level)", title: "Variable, V\(level)", detail: size,
                              apply: { $0.mp3Mode = .vbr; $0.mp3VBRQuality = level },
                              matches: { $0.mp3Mode == .vbr && $0.mp3VBRQuality == level })
            }
            return [cbr[0]] + vbr + cbr.dropFirst()
        case .aac:
            let rates = [(320, ""), (256, "Apple Music quality"), (192, ""), (128, "")]
            let lc = rates.map { rate, detail in
                QualityChoice(id: "aac\(rate)", title: "\(rate) kbps", detail: detail,
                              apply: { $0.aacProfile = .lc; $0.aacMode = .constrainedVBR; $0.aacBitrate = rate },
                              matches: { $0.aacProfile == .lc && $0.aacMode == .constrainedVBR && $0.aacBitrate == rate })
            }
            let he = QualityChoice(id: "he64", title: "64 kbps HE-AAC", detail: "For speech and small files",
                                   apply: { $0.aacProfile = .he; $0.aacMode = .constrainedVBR; $0.aacBitrate = 64 },
                                   matches: { $0.aacProfile == .he && $0.aacMode == .constrainedVBR && $0.aacBitrate == 64 })
            return lc + [he]
        case .vorbis:
            return [(10.0, "about 500 kbps"), (8.0, "about 256 kbps"), (6.0, "about 192 kbps"), (5.0, "about 160 kbps"), (3.0, "about 112 kbps")].map { quality, size in
                QualityChoice(id: "q\(Int(quality))", title: "Quality \(Int(quality))", detail: size,
                              apply: { $0.vorbisMode = .quality; $0.vorbisQuality = quality },
                              matches: { $0.vorbisMode == .quality && $0.vorbisQuality == quality })
            }
        case .opus:
            return [(256, ""), (192, ""), (160, "Transparent for most music"), (128, ""), (96, ""), (64, "Speech")].map { rate, detail in
                QualityChoice(id: "opus\(rate)", title: "\(rate) kbps", detail: detail,
                              apply: { $0.opusBitrate = rate }, matches: { $0.opusBitrate == rate })
            }
        }
    }
}

extension ConversionSettings {
    /// A short description of the format's quality settings, e.g. "320 kbps" or "24-bit".
    public var qualitySummary: String {
        switch format {
        case .wav, .aiff, .caf, .flac, .alac:
            return selectedDepth == .match ? "Same bit depth" : selectedDepth.title
        case .mp3:
            switch mp3Mode {
            case .cbr: return "\(mp3Bitrate) kbps"
            case .abr: return "Average \(mp3Bitrate) kbps"
            case .vbr: return "Variable, V\(mp3VBRQuality)"
            }
        case .aac:
            let profile = aacProfile == .he ? " HE-AAC" : ""
            switch aacMode {
            case .vbr: return "Variable, quality \(aacVBRQuality)\(profile)"
            case .cbr: return "\(aacBitrate) kbps constant\(profile)"
            case .abr: return "Average \(aacBitrate) kbps\(profile)"
            case .constrainedVBR: return "\(aacBitrate) kbps\(profile)"
            }
        case .vorbis:
            return vorbisMode == .quality ? "Quality \(Self.trimmed(vorbisQuality))" : "Average \(vorbisBitrate) kbps"
        case .opus:
            return "\(opusBitrate) kbps"
        }
    }

    /// Everything beyond the format's own quality that changes the sound, for the summary line.
    public var processingSummary: [String] {
        var parts: [String] = []
        if let rate = sampleRate { parts.append(Self.rateText(rate)) }
        if channels != .keep { parts.append(channels.title) }
        switch volume {
        case .none: break
        case .loudness: parts.append("\(Self.trimmed(loudnessTarget)) LUFS")
        case .peak: parts.append("Peaks \(Self.trimmed(peakTarget)) dB")
        case .gain: parts.append(String(format: "%+.1f dB", gainDB))
        }
        return parts
    }

    public static func rateText(_ rate: Double) -> String {
        let khz = rate / 1000
        return khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz)
    }

    static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
