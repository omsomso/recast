import AVFoundation
import AudioToolbox
import Foundation

/// What an audio file holds.
public struct AudioFileInfo: Sendable, Equatable {
    public var formatName: String
    public var sampleRate: Double
    public var channels: Int
    /// Bits per sample for PCM and lossless files; nil for compressed ones.
    public var bitDepth: Int?
    public var isFloat: Bool
    public var isLossless: Bool
    public var frames: Int64
    public var bitRate: Int?
    public var fileSize: Int64

    public var duration: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }

    public var channelText: String {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels) channels"
        }
    }

    /// e.g. "FLAC · 24-bit · 96 kHz · Stereo" or "MP3 · 320 kbps · 44.1 kHz · Stereo".
    public var summary: String {
        var parts = [formatName]
        if let bitDepth, isLossless { parts.append(isFloat ? "\(bitDepth)-bit float" : "\(bitDepth)-bit") }
        if !isLossless, let bitRate, bitRate > 0 { parts.append("\(Int((Double(bitRate) / 1000).rounded())) kbps") }
        parts.append(ConversionSettings.rateText(sampleRate))
        parts.append(channelText)
        return parts.joined(separator: " · ")
    }

    public static func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

public enum AudioProbe {
    /// File extensions offered in open panels and accepted from folders.
    public static let audioExtensions: Set<String> = [
        "wav", "wave", "bwf", "w64", "rf64", "aif", "aiff", "aifc", "caf", "flac", "m4a", "m4b", "m4r", "mp4", "aac", "adts",
        "mp3", "mp2", "mp1", "mpa", "ogg", "oga", "opus", "au", "snd", "sd2", "ac3", "ec3", "eac3", "amr", "3gp", "3g2", "mov",
    ]

    public static func info(_ url: URL) throws -> AudioFileInfo {
        let file = try openFile(url)
        defer { ExtAudioFileDispose(file) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format), "read the format of")
        var frames: Int64 = 0
        size = UInt32(MemoryLayout<Int64>.size)
        try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames), "measure")

        var audioFile: AudioFileID?
        size = UInt32(MemoryLayout<AudioFileID?>.size)
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioFile, &size, &audioFile)
        var fileType: AudioFileTypeID = 0
        var sourceDepth: Int32 = 0
        var bitRate: UInt32 = 0
        if let audioFile {
            size = UInt32(MemoryLayout<AudioFileTypeID>.size)
            AudioFileGetProperty(audioFile, kAudioFilePropertyFileFormat, &size, &fileType)
            size = UInt32(MemoryLayout<Int32>.size)
            AudioFileGetProperty(audioFile, kAudioFilePropertySourceBitDepth, &size, &sourceDepth)
            size = UInt32(MemoryLayout<UInt32>.size)
            AudioFileGetProperty(audioFile, kAudioFilePropertyBitRate, &size, &bitRate)
        }

        let id = format.mFormatID
        var bitDepth: Int?
        var isFloat = false
        let lossless = id == kAudioFormatLinearPCM || id == kAudioFormatFLAC || id == kAudioFormatAppleLossless
        if id == kAudioFormatLinearPCM {
            bitDepth = Int(format.mBitsPerChannel)
            isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        } else if lossless {
            if sourceDepth != 0 {
                bitDepth = Int(abs(sourceDepth))
                isFloat = sourceDepth < 0
            } else {
                bitDepth = [1: 16, 2: 20, 3: 24, 4: 32][format.mFormatFlags] ?? 16
            }
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        var rate = Int(bitRate)
        if rate == 0, frames > 0, format.mSampleRate > 0 { rate = Int(Double(fileSize) * 8 / (Double(frames) / format.mSampleRate)) }
        return AudioFileInfo(formatName: formatName(id: id, fileType: fileType), sampleRate: format.mSampleRate,
                             channels: Int(format.mChannelsPerFrame), bitDepth: bitDepth, isFloat: isFloat, isLossless: lossless,
                             frames: frames, bitRate: rate, fileSize: fileSize)
    }

    static func openFile(_ url: URL) throws -> ExtAudioFileRef {
        var file: ExtAudioFileRef?
        let status = ExtAudioFileOpenURL(url as CFURL, &file)
        guard status == noErr, let file else {
            throw ConversionError.unreadable("“\(url.lastPathComponent)” isn't an audio file macOS can read.")
        }
        return file
    }

    static func formatName(id: AudioFormatID, fileType: AudioFileTypeID) -> String {
        switch id {
        case kAudioFormatLinearPCM:
            switch fileType {
            case kAudioFileWAVEType, kAudioFileRF64Type, kAudioFileBW64Type: return "WAV"
            case kAudioFileWave64Type: return "Wave64"
            case kAudioFileAIFFType, kAudioFileAIFCType: return "AIFF"
            case kAudioFileCAFType: return "CAF"
            case kAudioFileNextType: return "AU"
            case kAudioFileSoundDesigner2Type: return "Sound Designer II"
            default: return "PCM"
            }
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatAppleLossless: return "Apple Lossless"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD: return "AAC"
        case kAudioFormatMPEG4AAC_HE: return "HE-AAC"
        case kAudioFormatMPEG4AAC_HE_V2: return "HE-AAC v2"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatMPEGLayer2: return "MP2"
        case kAudioFormatMPEGLayer1: return "MP1"
        case kAudioFormatOpus: return "Opus"
        case 0x766F_7262: return "Ogg Vorbis"
        case kAudioFormatAC3: return "AC-3"
        case kAudioFormatEnhancedAC3: return "E-AC-3"
        case kAudioFormatULaw: return "µ-law"
        case kAudioFormatALaw: return "A-law"
        case kAudioFormatAMR: return "AMR"
        case kAudioFormatAppleIMA4: return "IMA 4:1"
        default:
            let bytes = [UInt8(id >> 24 & 0xFF), UInt8(id >> 16 & 0xFF), UInt8(id >> 8 & 0xFF), UInt8(id & 0xFF)]
            return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces).uppercased() ?? "Audio"
        }
    }
}

func check(_ status: OSStatus, _ action: String, _ name: String = "the file") throws {
    guard status == noErr else { throw ConversionError.encoder("Couldn't \(action) \(name) (\(fourCharText(status))).") }
}

func fourCharText(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }), let text = String(bytes: bytes, encoding: .ascii) { return "'\(text)'" }
    return "error \(status)"
}

public enum ConversionError: LocalizedError, Equatable {
    case unreadable(String)
    case encoder(String)
    case cancelled
    case wouldReplaceOriginal

    public var errorDescription: String? {
        switch self {
        case .unreadable(let message), .encoder(let message): return message
        case .cancelled: return "Stopped."
        case .wouldReplaceOriginal: return "The converted file would replace the original."
        }
    }
}

/// Reads a file as 32-bit float, resampled by Core Audio's mastering-quality converter when the rate changes.
final class SourceReader {
    let file: ExtAudioFileRef
    let channels: Int
    let rate: Double

    init(url: URL, rate: Double) throws {
        file = try AudioProbe.openFile(url)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format)
        channels = Int(format.mChannelsPerFrame)
        self.rate = rate
        var client = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                                                 mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                 mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        do {
            try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: client)), &client),
                      "decode", "“\(url.lastPathComponent)”")
        } catch {
            ExtAudioFileDispose(file)
            throw error
        }
        if rate != format.mSampleRate {
            var converter: AudioConverterRef?
            size = UInt32(MemoryLayout<AudioConverterRef?>.size)
            if ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter) == noErr, let converter {
                var complexity = kAudioConverterSampleRateConverterComplexity_Mastering
                AudioConverterSetProperty(converter, kAudioConverterSampleRateConverterComplexity, 4, &complexity)
                var quality = UInt32(kAudioConverterQuality_Max)
                AudioConverterSetProperty(converter, kAudioConverterSampleRateConverterQuality, 4, &quality)
                var config: Unmanaged<CFArray>? = nil
                ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<Unmanaged<CFArray>?>.size), &config)
            }
        }
    }

    deinit { ExtAudioFileDispose(file) }

    /// Fills `buffer` (float, non-interleaved, `channels` wide); returns the frames read, 0 at the end.
    func read(into buffer: AVAudioPCMBuffer) throws -> Int {
        // AVAudioPCMBuffer sizes its buffer list from frameLength each time the list is fetched.
        buffer.frameLength = buffer.frameCapacity
        let list = buffer.mutableAudioBufferList
        var frames = buffer.frameCapacity
        try check(ExtAudioFileRead(file, &frames, list), "decode")
        buffer.frameLength = frames
        return Int(frames)
    }
}
