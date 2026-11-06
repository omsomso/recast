import AVFoundation
import Accelerate
import Foundation

/// Mixes between channel counts with ITU-style coefficients (standard WAV channel order: L R C LFE Ls Rs …).
struct ChannelMixer {
    let input: Int
    let output: Int
    /// matrix[out][in]
    let matrix: [[Float]]

    static func make(from input: Int, to output: Int) -> ChannelMixer? {
        guard input != output else { return nil }
        let half: Float = 0.5, side: Float = 0.70710678
        func stereoDownmix() -> [[Float]] {
            var left = [Float](repeating: 0, count: input), right = left
            switch input {
            case 1: left[0] = 1; right[0] = 1
            case 3: left[0] = 1; right[1] = 1; left[2] = side; right[2] = side
            case 4: left[0] = 1; right[1] = 1; left[2] = side; right[3] = side
            default:
                left[0] = 1; right[1] = 1
                if input > 2 { left[2] = side; right[2] = side }
                // LFE (channel 4 in 5.1 and 7.1 layouts) is left out, as ITU downmixes do.
                let lfe = input == 6 || input >= 8 ? 3 : -1
                var toLeft = true
                for channel in 3..<input where channel != lfe {
                    if toLeft { left[channel] = side } else { right[channel] = side }
                    toLeft.toggle()
                }
            }
            return [left, right]
        }
        switch output {
        case 1:
            if input == 2 { return ChannelMixer(input: 2, output: 1, matrix: [[half, half]]) }
            let stereo = stereoDownmix()
            return ChannelMixer(input: input, output: 1, matrix: [zip(stereo[0], stereo[1]).map { ($0 + $1) * half }])
        case 2:
            return ChannelMixer(input: input, output: 2, matrix: stereoDownmix())
        default:
            // Other counts: keep matching channels, silence the rest.
            let matrix = (0..<output).map { out in (0..<input).map { $0 == out ? Float(1) : 0 } }
            return ChannelMixer(input: input, output: output, matrix: matrix)
        }
    }

    func process(_ source: AVAudioPCMBuffer, into destination: AVAudioPCMBuffer) {
        let frames = Int(source.frameLength)
        destination.frameLength = source.frameLength
        guard let inData = source.floatChannelData, let outData = destination.floatChannelData else { return }
        for out in 0..<output {
            let target = outData[out]
            vDSP_vclr(target, 1, vDSP_Length(frames))
            for channel in 0..<input {
                var weight = matrix[out][channel]
                if weight == 0 { continue }
                vDSP_vsma(inData[channel], 1, &weight, target, 1, target, 1, vDSP_Length(frames))
            }
        }
    }
}

/// Turns float samples into integers of a given width, with optional TPDF dither and noise shaping.
/// Output values are left-justified in 32 bits, which Core Audio packs to the file's width without changing them.
struct Quantizer {
    let bits: Int
    let dither: Bool
    let shaping: Bool
    private var history: [[Float]]
    private var random: UInt64 = 0x9E37_79B9_7F4A_7C15
    private(set) var clipped = 0

    /// Wannamaker's 3-tap F-weighted noise shaping (for 44.1 and 48 kHz).
    private static let shape: [Float] = [1.623, -0.982, 0.109]

    init(bits: Int, channels: Int, dither: Bool, shaping: Bool) {
        self.bits = bits
        self.dither = dither && bits < 32
        self.shaping = shaping && dither && bits < 32
        history = Array(repeating: [0, 0, 0], count: channels)
    }

    private mutating func uniform() -> Float {
        random ^= random << 13
        random ^= random >> 7
        random ^= random << 17
        return Float(random >> 40) / Float(1 << 24)
    }

    mutating func process(_ source: AVAudioPCMBuffer, gain: Float, into destination: AVAudioPCMBuffer) {
        let frames = Int(source.frameLength)
        destination.frameLength = source.frameLength
        guard let inData = source.floatChannelData, let outData = destination.int32ChannelData else { return }
        let scale = Float(bits == 32 ? 2_147_483_648.0 : Double(1 << (bits - 1)))
        let maxValue = Double(bits == 32 ? Int64(Int32.max) : Int64(1 << (bits - 1)) - 1)
        let minValue = Double(bits == 32 ? Int64(Int32.min) : -Int64(1 << (bits - 1)))
        let shift = Int32(32 - bits)
        let gainScale = gain * scale
        for channel in 0..<source.format.channelCount.intValue {
            let input = inData[channel], output = outData[channel]
            var e1 = history[channel][0], e2 = history[channel][1], e3 = history[channel][2]
            for index in 0..<frames {
                var value = input[index] * gainScale
                if shaping { value -= Quantizer.shape[0] * e1 + Quantizer.shape[1] * e2 + Quantizer.shape[2] * e3 }
                var target = value
                if dither { target += uniform() - uniform() }
                var rounded = Double(target).rounded()
                if rounded > maxValue { rounded = maxValue; clipped += 1 } else if rounded < minValue { rounded = minValue; clipped += 1 }
                if shaping {
                    e3 = e2; e2 = e1
                    e1 = Float(rounded) - value
                    // Keep the feedback bounded when the signal clips hard.
                    e1 = max(-4, min(4, e1))
                }
                output[index] = Int32(rounded) << shift
            }
            history[channel] = [e1, e2, e3]
        }
    }
}

extension AVAudioChannelCount {
    var intValue: Int { Int(self) }
}

/// Applies a gain to float samples in place and counts samples beyond full scale.
func applyGain(_ buffer: AVAudioPCMBuffer, gain: Float) -> Int {
    guard let data = buffer.floatChannelData else { return 0 }
    let frames = vDSP_Length(buffer.frameLength)
    var overs = 0
    for channel in 0..<buffer.format.channelCount.intValue {
        if gain != 1 {
            var factor = gain
            vDSP_vsmul(data[channel], 1, &factor, data[channel], 1, frames)
        }
        var peak: Float = 0
        vDSP_maxmgv(data[channel], 1, &peak, frames)
        if peak > 1 {
            for index in 0..<Int(frames) where abs(data[channel][index]) > 1 { overs += 1 }
        }
    }
    return overs
}
