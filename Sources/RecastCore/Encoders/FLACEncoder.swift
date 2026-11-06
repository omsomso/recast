import AVFoundation
import CryptoKit
import Foundation

/// FLAC through Core Audio, except for files shorter than one FLAC block (4608 frames, about 0.1 s): Core Audio
/// writes those as a broken 42-byte file, so they get a single uncompressed (verbatim) frame written here instead.
final class FLACEncoder: AudioEncoder {
    static let blockFrames = 4608

    let inputFormat: AVAudioFormat
    var notes: [String] { coreAudio?.notes ?? [] }
    private let setup: EncoderSetup
    private var coreAudio: CoreAudioEncoder?
    private var pending: [[Int32]]

    init(_ setup: EncoderSetup) throws {
        self.setup = setup
        inputFormat = int32Format(rate: setup.sampleRate, channels: setup.channels)
        pending = Array(repeating: [], count: setup.channels)
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        if let coreAudio { try coreAudio.write(buffer); return }
        guard let data = buffer.int32ChannelData else { return }
        let frames = Int(buffer.frameLength)
        for channel in 0..<setup.channels { pending[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: frames)) }
        if pending[0].count >= FLACEncoder.blockFrames { try startCoreAudio() }
    }

    private func startCoreAudio() throws {
        let encoder = try CoreAudioEncoder(setup)
        coreAudio = encoder
        let frames = pending[0].count
        let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<setup.channels { buffer.int32ChannelData![channel].update(from: pending[channel], count: frames) }
        pending = []
        try encoder.write(buffer)
    }

    func finish() throws {
        if let coreAudio { try coreAudio.finish(); return }
        try FLACEncoder.writeVerbatim(pending, sampleRate: Int(setup.sampleRate), bits: setup.bits ?? 24, to: setup.url)
    }

    func abort() { coreAudio?.abort() }

    /// A complete FLAC file holding `samples` (left-justified Int32, one array per channel) in one verbatim frame.
    static func writeVerbatim(_ samples: [[Int32]], sampleRate: Int, bits: Int, to url: URL) throws {
        let channels = samples.count
        let frames = samples.first?.count ?? 0
        let shift = Int32(32 - bits)
        let bytesPerSample = bits / 8
        var frame = Data()
        if frames > 0 {
            var header = ByteWriter()
            header.u8(0xFF)
            header.u8(0xF8) // sync, fixed block size
            let sizeCodes: [Int: UInt8] = [8: 0b001, 12: 0b010, 16: 0b100, 20: 0b101, 24: 0b110, 32: 0b111]
            // Block size: 16 bits after the frame number. The sample rate is coded in the frame too: Core Audio's
            // decoder rejects frames that refer to the stream info for it.
            let rateCodes: [Int: UInt8] = [88200: 1, 176400: 2, 192000: 3, 8000: 4, 16000: 5, 22050: 6, 24000: 7,
                                           32000: 8, 44100: 9, 48000: 10, 96000: 11]
            var rateCode: UInt8
            var rateBytes = ByteWriter()
            if let code = rateCodes[sampleRate] {
                rateCode = code
            } else if sampleRate % 1000 == 0, sampleRate / 1000 < 256 {
                rateCode = 12; rateBytes.u8(UInt8(sampleRate / 1000))
            } else if sampleRate < 65536 {
                rateCode = 13; rateBytes.u16be(UInt16(sampleRate))
            } else {
                rateCode = 14; rateBytes.u16be(UInt16(clamping: sampleRate / 10))
            }
            header.u8(0b0111_0000 | rateCode)
            header.u8(UInt8(channels - 1) << 4 | (sizeCodes[bits] ?? 0) << 1)
            header.u8(0) // frame number 0
            header.u16be(UInt16(frames - 1))
            header.append(rateBytes.data)
            header.u8(crc8(header.data))
            frame = header.data
            for channel in 0..<channels {
                frame.append(0b0000_0010) // verbatim subframe, no wasted bits
                var bytes = [UInt8](repeating: 0, count: frames * bytesPerSample)
                for index in 0..<frames {
                    let value = UInt32(bitPattern: samples[channel][index] >> shift)
                    for byte in 0..<bytesPerSample {
                        bytes[index * bytesPerSample + byte] = UInt8(truncatingIfNeeded: value >> UInt32(8 * (bytesPerSample - 1 - byte)))
                    }
                }
                frame.append(contentsOf: bytes)
            }
            var crc = ByteWriter()
            crc.u16be(crc16(frame))
            frame.append(crc.data)
        }
        // MD5 of the samples as little-endian interleaved integers, as FLAC defines it.
        var md5 = Insecure.MD5()
        var interleaved = [UInt8]()
        interleaved.reserveCapacity(frames * channels * bytesPerSample)
        for index in 0..<frames {
            for channel in 0..<channels {
                let value = UInt32(bitPattern: samples[channel][index] >> shift)
                for byte in 0..<bytesPerSample { interleaved.append(UInt8(truncatingIfNeeded: value >> UInt32(8 * byte))) }
            }
        }
        md5.update(data: interleaved)
        var info = ByteWriter()
        let block = UInt16(max(16, frames))
        info.u16be(block)
        info.u16be(block)
        info.u24be(UInt32(frame.count))
        info.u24be(UInt32(frame.count))
        // 20 bits rate, 3 bits channels-1, 5 bits bits-1, 36 bits total samples.
        let packed = UInt64(sampleRate) << 44 | UInt64(channels - 1) << 41 | UInt64(bits - 1) << 36 | UInt64(frames)
        info.u64be(packed)
        info.append(Data(md5.finalize()))
        var file = Data("fLaC".utf8)
        file.append(0x80) // last metadata block, STREAMINFO
        var length = ByteWriter()
        length.u24be(UInt32(info.data.count))
        file.append(length.data)
        file.append(info.data)
        file.append(frame)
        try file.write(to: url)
    }

    static func crc8(_ data: Data) -> UInt8 {
        var crc: UInt8 = 0
        for byte in data {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        return crc
    }

    static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x8005 : crc << 1 }
        }
        return crc
    }
}
