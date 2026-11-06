import AVFoundation
import AppKit
import XCTest
@testable import RecastCore

/// Generated audio and helpers. Everything is written into a fresh temporary folder per test.
enum Fixtures {
    /// A fresh folder, deleted when the test ends (set RECAST_KEEP_TEST_FILES=1 to keep it).
    static func folder(_ name: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecastTests-\(name.filter { $0.isLetter || $0.isNumber })-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["RECAST_KEEP_TEST_FILES"] == nil {
            currentTest?.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        }
        return url
    }

    nonisolated(unsafe) static var currentTest: XCTestCase?

    /// A deterministic signal: a sweep plus a little noise, different per channel.
    static func signal(frames: Int, channels: Int, rate: Double, level: Float = 0.5) -> [[Float]] {
        var seed: UInt32 = 12345
        return (0..<channels).map { channel in
            (0..<frames).map { index in
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.02
                let t = Double(index) / rate
                let sweep = sin(2 * .pi * (200 * t + 900 * t * t)) // 200 Hz rising
                return level * Float(sweep) * (channel == 0 ? 1 : 0.7) + noise
            }
        }
    }

    static func sine(frequency: Double, frames: Int, rate: Double, amplitude: Float, channels: Int = 2) -> [[Float]] {
        let wave = (0..<frames).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
        return Array(repeating: wave, count: channels)
    }

    /// Rounds samples to `bits` so a file of that depth holds them exactly.
    static func quantized(_ samples: [[Float]], bits: Int) -> [[Float]] {
        let scale = Float(1 << (bits - 1))
        return samples.map { $0.map { (($0 * scale).rounded()) / scale } }
    }

    /// Writes PCM through Core Audio (integer files get exactly the given values when they are pre-quantized).
    static func writePCM(_ samples: [[Float]], rate: Double, bits: Int, float: Bool = false, to url: URL,
                         type: AVFileType? = nil) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: samples.count,
            AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: float, AVLinearPCMIsBigEndianKey: url.pathExtension.hasPrefix("aif"),
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples[0].count))!
        buffer.frameLength = AVAudioFrameCount(samples[0].count)
        for (channel, values) in samples.enumerated() { buffer.floatChannelData![channel].update(from: values, count: values.count) }
        try file.write(from: buffer)
    }

    static func read(_ url: URL) throws -> (samples: [[Float]], rate: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let channels = Int(file.processingFormat.channelCount)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536)!
        var samples = Array(repeating: [Float](), count: channels)
        // A single read may return fewer frames than asked for.
        while file.framePosition < file.length {
            // Compressed files can report a length slightly past their last decodable frame.
            do { try file.read(into: buffer) } catch { if samples[0].isEmpty { throw error }; break }
            if buffer.frameLength == 0 { break }
            for channel in 0..<channels {
                samples[channel].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
            }
        }
        return (samples, file.processingFormat.sampleRate)
    }

    static let artwork: Data = {
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        NSColor.white.setFill()
        NSRect(x: 16, y: 16, width: 32, height: 32).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }()

    static var tags: AudioTags {
        var tags = AudioTags()
        tags.title = "Café Ünïcode Title"
        tags.artist = "The Artist"
        tags.album = "Test Album"
        tags.albumArtist = "Various"
        tags.composer = "A. Composer"
        tags.genre = "Electronic"
        tags.date = "2024"
        tags.comment = "A comment"
        tags.track = 3
        tags.trackTotal = 12
        tags.disc = 1
        tags.discTotal = 2
        tags.bpm = 120
        tags.compilation = true
        tags.extra["MUSICBRAINZ_TRACKID"] = "abc-123"
        tags.artwork = Artwork(data: artwork, mimeType: "image/png")
        return tags
    }

    static func rms(_ values: [Float]) -> Double {
        guard !values.isEmpty else { return 0 }
        return sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(values.count))
    }

    static func peak(_ samples: [[Float]]) -> Float { samples.flatMap { $0 }.map(abs).max() ?? 0 }

    /// The lag (decoded minus source, in samples) that best lines up two signals, and the correlation there.
    static func alignment(_ source: [Float], _ decoded: [Float], maxLag: Int = 4000) -> (lag: Int, correlation: Double) {
        let window = min(source.count, decoded.count) - maxLag - 1
        let start = maxLag
        guard window > 1000 else { return (0, 0) }
        var best = (lag: 0, correlation: -1.0)
        for lag in -maxLag...maxLag {
            var dot = 0.0, a = 0.0, b = 0.0
            var index = start
            while index < start + window - maxLag {
                let x = Double(source[index]), y = Double(decoded[index + lag])
                dot += x * y; a += x * x; b += y * y
                index += 4
            }
            let correlation = dot / max(1e-12, sqrt(a * b))
            if correlation > best.correlation { best = (lag, correlation) }
        }
        return best
    }

    static func settings(_ format: OutputFormat, _ edit: (inout ConversionSettings) -> Void = { _ in }) -> ConversionSettings {
        var settings = ConversionSettings()
        settings.format = format
        edit(&settings)
        return settings
    }

    @discardableResult
    static func convert(_ input: URL, _ settings: ConversionSettings, name: String? = nil) throws -> ConversionOutcome {
        let output = input.deletingLastPathComponent()
            .appendingPathComponent(name ?? "\(input.deletingPathExtension().lastPathComponent)-out")
            .appendingPathExtension(settings.format.fileExtension)
        return try Converter.convert(input: input, to: output, settings: settings)
    }
}
