import AVFoundation
import Foundation

/// Level measurements of a whole file, as Recast's volume settings see them.
public struct LevelMeasurement: Sendable, Equatable {
    /// Integrated loudness in LUFS (EBU R128); -inf for silence.
    public var loudness: Double
    /// Highest sample, dBFS.
    public var samplePeak: Double
    /// Highest point between samples (4× oversampled), dBTP.
    public var truePeak: Double
}

public enum AudioAnalysis {
    public static func measure(_ url: URL) throws -> LevelMeasurement {
        let info = try AudioProbe.info(url)
        let reader = try SourceReader(url: url, rate: info.sampleRate)
        let meter = LoudnessMeter(channels: info.channels, sampleRate: info.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: floatFormat(rate: info.sampleRate, channels: info.channels), frameCapacity: 8192)!
        while try reader.read(into: buffer) > 0 { meter.process(buffer) }
        return LevelMeasurement(loudness: meter.integratedLoudness, samplePeak: LoudnessMeter.decibels(meter.samplePeak),
                                truePeak: LoudnessMeter.decibels(meter.truePeak))
    }
}
