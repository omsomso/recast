import AVFoundation
import Foundation

/// Integrated loudness (ITU-R BS.1770-4 / EBU R128), sample peak and true peak (4× oversampled), measured block by block.
final class LoudnessMeter {
    private struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private let channels: Int
    private let weights: [Double]
    private var shelf: [Biquad]
    private var highpass: [Biquad]
    private let stepFrames: Int // 100 ms
    private var stepEnergy: [Double]
    private var stepCount = 0
    private var steps: [Double] = [] // per 100 ms step: weighted sum of mean squares
    private var totalEnergy = 0.0
    private var totalFrames = 0

    private(set) var samplePeak: Float = 0
    private var truePeakValue: Float = 0
    private var history: [[Float]]
    private var historyIndex = 0
    private static let phases = 4
    private static let taps = 12
    private static let coefficients: [[Float]] = {
        // Windowed-sinc 4× interpolator, 48 taps (12 per phase), as in BS.1770-4 Annex 2.
        let length = phases * taps
        let center = Double(length - 1) / 2
        var phaseTable = Array(repeating: [Float](repeating: 0, count: taps), count: phases)
        for n in 0..<length {
            let t = (Double(n) - center) / Double(phases)
            let sinc = t == 0 ? 1 : sin(.pi * t) / (.pi * t)
            let window = 0.42 - 0.5 * cos(2 * .pi * Double(n) / Double(length - 1)) + 0.08 * cos(4 * .pi * Double(n) / Double(length - 1))
            phaseTable[n % phases][n / phases] = Float(sinc * window)
        }
        return phaseTable
    }()

    init(channels: Int, sampleRate: Double) {
        self.channels = channels
        // Surround channels weigh 1.41; LFE is not counted.
        weights = (0..<channels).map { channel in
            if channels == 6 || channels >= 8 { if channel == 3 { return 0 }; if channel >= 4 { return 1.41 } }
            if channels == 5, channel >= 3 { return 1.41 }
            return 1
        }
        // K-weighting for any sample rate (the BS.1770 filters re-derived from their analog prototypes).
        var f0 = 1681.974450955533, gain = 3.999843853973347, q = 0.7071752369554196
        var k = tan(.pi * f0 / sampleRate)
        let vh = pow(10, gain / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelfFilter = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                                 a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        f0 = 38.13547087602444; q = 0.5003270373238773; gain = 0
        k = tan(.pi * f0 / sampleRate)
        a0 = 1 + k / q + k * k
        let highpassFilter = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        shelf = Array(repeating: shelfFilter, count: channels)
        highpass = Array(repeating: highpassFilter, count: channels)
        stepFrames = max(1, Int((sampleRate / 10).rounded()))
        stepEnergy = Array(repeating: 0, count: channels)
        history = Array(repeating: [Float](repeating: 0, count: LoudnessMeter.taps), count: channels)
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let coefficients = LoudnessMeter.coefficients
        let taps = LoudnessMeter.taps
        for index in 0..<frames {
            for channel in 0..<channels {
                let sample = data[channel][index]
                let magnitude = abs(sample)
                if magnitude > samplePeak { samplePeak = magnitude }
                // True peak: interpolate the three points between this sample and the last.
                history[channel][historyIndex] = sample
                for phase in 0..<LoudnessMeter.phases {
                    var sum: Float = 0
                    var position = historyIndex
                    let row = coefficients[phase]
                    for tap in 0..<taps {
                        sum += row[tap] * history[channel][position]
                        position = position == 0 ? taps - 1 : position - 1
                    }
                    let value = abs(sum)
                    if value > truePeakValue { truePeakValue = value }
                }
                guard weights[channel] > 0 else { continue }
                let filtered = highpass[channel].process(shelf[channel].process(Double(sample)))
                stepEnergy[channel] += filtered * filtered
            }
            historyIndex = (historyIndex + 1) % taps
            stepCount += 1
            if stepCount == stepFrames { closeStep() }
        }
    }

    private func closeStep() {
        var sum = 0.0
        for channel in 0..<channels { sum += weights[channel] * stepEnergy[channel] / Double(stepCount) }
        steps.append(sum)
        totalEnergy += sum * Double(stepCount)
        totalFrames += stepCount
        stepEnergy = Array(repeating: 0, count: channels)
        stepCount = 0
    }

    /// Integrated loudness in LUFS; -inf for silence.
    var integratedLoudness: Double {
        var blocks: [Double] = []
        if steps.count >= 4 {
            for start in 0...(steps.count - 4) { blocks.append((steps[start] + steps[start + 1] + steps[start + 2] + steps[start + 3]) / 4) }
        } else if totalFrames + stepCount > 0 {
            // Shorter than one 400 ms block: use the whole file.
            var sum = totalEnergy
            for channel in 0..<channels { sum += weights[channel] * stepEnergy[channel] }
            blocks.append(sum / Double(totalFrames + stepCount))
        }
        func loudness(_ energy: Double) -> Double { -0.691 + 10 * log10(energy) }
        let absolute = blocks.filter { $0 > 0 && loudness($0) > -70 }
        guard !absolute.isEmpty else { return -.infinity }
        let threshold = loudness(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let relative = absolute.filter { loudness($0) > threshold }
        guard !relative.isEmpty else { return -.infinity }
        return loudness(relative.reduce(0, +) / Double(relative.count))
    }

    var truePeak: Float { max(truePeakValue, samplePeak) }

    static func decibels(_ linear: Float) -> Double { linear > 0 ? 20 * log10(Double(linear)) : -.infinity }
}
