import AVFoundation
import CLame
import Foundation

/// MP3 through LAME 3.100: ID3v2.4 tag first, then the frames; the LAME/Xing header (length and gapless
/// information) is filled in at the end.
final class MP3Encoder: AudioEncoder {
    let inputFormat: AVAudioFormat
    private(set) var notes: [String] = []
    private var lame: lame_t?
    private let handle: FileHandle
    private let channels: Int
    private var output = [UInt8]()
    private let tagSize: UInt64

    init(_ setup: EncoderSetup) throws {
        channels = setup.channels
        inputFormat = floatFormat(rate: setup.sampleRate, channels: setup.channels)
        FileManager.default.createFile(atPath: setup.url.path, contents: nil)
        handle = try FileHandle(forWritingTo: setup.url)
        let tag = setup.tags.isEmpty ? Data() : ID3.makeTag(setup.tags, version: 4, includeArtwork: setup.includeArtwork, padding: 512)
        tagSize = UInt64(tag.count)
        try handle.write(contentsOf: tag)

        guard let lame = lame_init() else { throw ConversionError.encoder("The MP3 encoder couldn't start.") }
        self.lame = lame
        // LAME reports to stderr by default; Recast shows its own messages.
        lame_set_errorf(lame) { _, _ in }
        lame_set_debugf(lame) { _, _ in }
        lame_set_msgf(lame) { _, _ in }
        let settings = setup.settings
        lame_set_in_samplerate(lame, Int32(setup.sampleRate))
        lame_set_out_samplerate(lame, Int32(setup.sampleRate))
        lame_set_num_channels(lame, Int32(setup.channels))
        lame_set_mode(lame, setup.channels == 1 ? MONO : (settings.mp3JointStereo ? JOINT_STEREO : STEREO))
        lame_set_quality(lame, 2)
        switch settings.mp3Mode {
        case .cbr:
            lame_set_VBR(lame, vbr_off)
            lame_set_brate(lame, Int32(settings.mp3Bitrate))
        case .abr:
            lame_set_VBR(lame, vbr_abr)
            lame_set_VBR_mean_bitrate_kbps(lame, Int32(settings.mp3Bitrate))
        case .vbr:
            lame_set_VBR(lame, vbr_default)
            lame_set_VBR_quality(lame, Float(max(0, min(9, settings.mp3VBRQuality))))
        }
        lame_set_bWriteVbrTag(lame, 1)
        lame_set_write_id3tag_automatic(lame, 0)
        guard lame_init_params(lame) >= 0 else {
            lame_close(lame)
            self.lame = nil
            try? handle.close()
            throw ConversionError.encoder("The MP3 encoder doesn't accept these settings at \(ConversionSettings.rateText(setup.sampleRate)).")
        }
        if settings.mp3Mode != .vbr {
            let actual = Int(lame_get_brate(lame))
            if settings.mp3Mode == .cbr, actual != settings.mp3Bitrate {
                notes.append("MP3 at \(ConversionSettings.rateText(setup.sampleRate)) allows \(actual) kbps at most; used that.")
            }
        }
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let lame, let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let capacity = frames * 5 / 4 + 7200
        if output.count < capacity { output = [UInt8](repeating: 0, count: capacity) }
        let left = data[0], right = channels > 1 ? data[1] : data[0]
        let written = output.withUnsafeMutableBufferPointer { out in
            lame_encode_buffer_ieee_float(lame, left, right, Int32(frames), out.baseAddress, Int32(capacity))
        }
        guard written >= 0 else { throw ConversionError.encoder("The MP3 encoder failed (\(written)).") }
        try handle.write(contentsOf: Data(output.prefix(Int(written))))
    }

    func finish() throws {
        guard let lame else { return }
        if output.count < 7200 { output = [UInt8](repeating: 0, count: 7200) }
        let flushed = output.withUnsafeMutableBufferPointer { lame_encode_flush(lame, $0.baseAddress, Int32($0.count)) }
        if flushed > 0 { try handle.write(contentsOf: Data(output.prefix(Int(flushed)))) }
        var frame = [UInt8](repeating: 0, count: 2880)
        let size = frame.withUnsafeMutableBufferPointer { lame_get_lametag_frame(lame, $0.baseAddress, $0.count) }
        if size > 0, size <= frame.count {
            try handle.seek(toOffset: tagSize)
            try handle.write(contentsOf: Data(frame.prefix(size)))
        }
        lame_close(lame)
        self.lame = nil
        try handle.close()
    }

    func abort() {
        if let lame { lame_close(lame) }
        lame = nil
        try? handle.close()
    }

    deinit { if lame != nil { abort() } }
}
