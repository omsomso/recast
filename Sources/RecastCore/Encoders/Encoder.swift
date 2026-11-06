import AVFoundation
import AudioToolbox
import Foundation

/// What the pipeline hands an encoder.
struct EncoderSetup {
    var url: URL
    var format: OutputFormat
    var sampleRate: Double
    var channels: Int
    /// Integer width for PCM and lossless outputs; nil for float and compressed outputs.
    var bits: Int?
    var isFloat: Bool
    var settings: ConversionSettings
    /// Tags the encoder embeds itself (MP3, Ogg, CAF); others are written after encoding.
    var tags: AudioTags
    var includeArtwork: Bool
    var estimatedFrames: Int64
    var sourceRate: Double
}

protocol AudioEncoder: AnyObject {
    /// Float32 or Int32 (left-justified), non-interleaved.
    var inputFormat: AVAudioFormat { get }
    var notes: [String] { get }
    func write(_ buffer: AVAudioPCMBuffer) throws
    func finish() throws
    /// Closes without finishing; the caller deletes the file.
    func abort()
}

enum EncoderFactory {
    static func make(_ setup: EncoderSetup) throws -> AudioEncoder {
        switch setup.format {
        case .wav, .aiff, .caf, .alac, .aac: return try CoreAudioEncoder(setup)
        case .flac: return try FLACEncoder(setup)
        case .mp3: return try MP3Encoder(setup)
        case .vorbis: return try VorbisEncoder(setup)
        case .opus: return try OpusEncoder(setup)
        }
    }
}

func floatFormat(rate: Double, channels: Int) -> AVAudioFormat { pcmFormat(.pcmFormatFloat32, rate: rate, channels: channels) }

func int32Format(rate: Double, channels: Int) -> AVAudioFormat { pcmFormat(.pcmFormatInt32, rate: rate, channels: channels) }

/// AVAudioFormat needs a channel layout above two channels; channels stay in file order.
private func pcmFormat(_ common: AVAudioCommonFormat, rate: Double, channels: Int) -> AVAudioFormat {
    if channels <= 2 {
        return AVAudioFormat(commonFormat: common, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false)!
    }
    let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels))!
    return AVAudioFormat(commonFormat: common, sampleRate: rate, interleaved: false, channelLayout: layout)
}

/// WAV, AIFF, CAF, FLAC, Apple Lossless and AAC through ExtAudioFile.
final class CoreAudioEncoder: AudioEncoder {
    let inputFormat: AVAudioFormat
    private(set) var notes: [String] = []
    private var file: ExtAudioFileRef?
    private let setup: EncoderSetup

    init(_ setup: EncoderSetup) throws {
        self.setup = setup
        let channels = UInt32(setup.channels)
        var fileType: AudioFileTypeID
        var format = AudioStreamBasicDescription()
        format.mSampleRate = setup.sampleRate
        format.mChannelsPerFrame = channels
        let losslessFlag: (Int) -> UInt32 = { bits in
            switch bits {
            case 16: return kAppleLosslessFormatFlag_16BitSourceData
            case 20: return kAppleLosslessFormatFlag_20BitSourceData
            case 24: return kAppleLosslessFormatFlag_24BitSourceData
            default: return kAppleLosslessFormatFlag_32BitSourceData
            }
        }
        switch setup.format {
        case .wav, .aiff, .caf:
            let bits = UInt32(setup.isFloat ? 32 : setup.bits ?? 24)
            format.mFormatID = kAudioFormatLinearPCM
            format.mFormatFlags = (setup.isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked
            if setup.format == .aiff { format.mFormatFlags |= kAudioFormatFlagIsBigEndian }
            format.mBitsPerChannel = bits
            format.mBytesPerFrame = bits / 8 * channels
            format.mBytesPerPacket = format.mBytesPerFrame
            format.mFramesPerPacket = 1
            switch setup.format {
            case .wav:
                let bytes = setup.estimatedFrames * Int64(format.mBytesPerFrame)
                fileType = bytes > 4_000_000_000 ? kAudioFileRF64Type : kAudioFileWAVEType
            case .aiff: fileType = setup.isFloat ? kAudioFileAIFCType : kAudioFileAIFFType
            default: fileType = kAudioFileCAFType
            }
        case .flac:
            format.mFormatID = kAudioFormatFLAC
            format.mFormatFlags = losslessFlag(setup.bits ?? 24)
            fileType = kAudioFileFLACType
        case .alac:
            format.mFormatID = kAudioFormatAppleLossless
            format.mFormatFlags = losslessFlag(setup.bits ?? 24)
            format.mFramesPerPacket = 4096
            fileType = kAudioFileM4AType
        case .aac:
            format.mFormatID = setup.settings.aacProfile == .he ? kAudioFormatMPEG4AAC_HE : kAudioFormatMPEG4AAC
            fileType = kAudioFileM4AType
        default:
            throw ConversionError.encoder("Core Audio doesn't write \(setup.format.title).")
        }

        var created: ExtAudioFileRef?
        try check(ExtAudioFileCreateWithURL(setup.url as CFURL, fileType, &format, nil, AudioFileFlags.eraseFile.rawValue, &created),
                  "create", "the \(setup.format.title) file")
        guard let created else { throw ConversionError.encoder("Couldn't create the \(setup.format.title) file.") }
        file = created

        let integerInput = setup.bits != nil && !setup.isFloat
        inputFormat = integerInput ? int32Format(rate: setup.sampleRate, channels: setup.channels)
                                   : floatFormat(rate: setup.sampleRate, channels: setup.channels)
        var client = inputFormat.streamDescription.pointee
        do {
            try check(ExtAudioFileSetProperty(created, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: client)), &client),
                      "prepare", "the encoder")
            try configureCodec(created)
        } catch {
            abort()
            throw error
        }
    }

    private func configureCodec(_ file: ExtAudioFileRef) throws {
        guard setup.format == .aac || setup.format == .flac || setup.format == .alac else { return }
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter) == noErr, let converter else { return }
        let settings = setup.settings
        var quality = UInt32(kAudioConverterQuality_Max)
        if setup.format == .flac, settings.flacFast { quality = UInt32(kAudioConverterQuality_Min) }
        AudioConverterSetProperty(converter, kAudioConverterCodecQuality, 4, &quality)
        if setup.format == .aac {
            var mode: UInt32
            switch settings.aacMode {
            case .cbr: mode = kAudioCodecBitRateControlMode_Constant
            case .abr: mode = kAudioCodecBitRateControlMode_LongTermAverage
            case .constrainedVBR: mode = kAudioCodecBitRateControlMode_VariableConstrained
            case .vbr: mode = kAudioCodecBitRateControlMode_Variable
            }
            AudioConverterSetProperty(converter, kAudioCodecPropertyBitRateControlMode, 4, &mode)
            if settings.aacMode == .vbr {
                var vbrQuality = UInt32(max(0, min(127, settings.aacVBRQuality)))
                AudioConverterSetProperty(converter, kAudioCodecPropertySoundQualityForVBR, 4, &vbrQuality)
            } else {
                let wanted = Double(settings.aacBitrate * 1000)
                var bitRate = UInt32(nearestBitRate(converter, to: wanted))
                if Double(bitRate) != wanted { notes.append("AAC at this rate and channel count allows \(bitRate / 1000) kbps at most; used that.") }
                try check(AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, 4, &bitRate), "set the bit rate of", "the AAC encoder")
            }
        }
        var config: Unmanaged<CFArray>? = nil
        try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<Unmanaged<CFArray>?>.size), &config),
                  "configure", "the encoder")
    }

    private func nearestBitRate(_ converter: AudioConverterRef, to wanted: Double) -> Double {
        var size: UInt32 = 0
        guard AudioConverterGetPropertyInfo(converter, kAudioConverterApplicableEncodeBitRates, &size, nil) == noErr, size > 0 else { return wanted }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioConverterGetProperty(converter, kAudioConverterApplicableEncodeBitRates, &size, &ranges) == noErr else { return wanted }
        let values = ranges.flatMap { [$0.mMinimum, $0.mMaximum] }.filter { $0 > 0 }
        if values.contains(where: { abs($0 - wanted) < 1 }) { return wanted }
        let below = values.filter { $0 <= wanted }
        return below.max() ?? values.min() ?? wanted
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let file else { return }
        try check(ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList), "write", "the \(setup.format.title) file")
    }

    func finish() throws {
        guard let file else { return }
        if setup.format == .caf, !setup.tags.isEmpty {
            var audioFile: AudioFileID?
            var size = UInt32(MemoryLayout<AudioFileID?>.size)
            if ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioFile, &size, &audioFile) == noErr, let audioFile {
                let dictionary = TagIO.coreAudioDictionary(setup.tags) as CFDictionary
                var reference = Unmanaged.passUnretained(dictionary)
                withExtendedLifetime(dictionary) {
                    _ = AudioFileSetProperty(audioFile, kAudioFilePropertyInfoDictionary, UInt32(MemoryLayout<Unmanaged<CFDictionary>>.size), &reference)
                }
            }
            if setup.includeArtwork, setup.tags.artwork != nil { notes.append("CAF files can't hold cover art; it was left out.") }
        }
        self.file = nil
        try check(ExtAudioFileDispose(file), "finish", "the \(setup.format.title) file")
    }

    func abort() {
        if let file { ExtAudioFileDispose(file) }
        file = nil
    }

    deinit { abort() }
}
