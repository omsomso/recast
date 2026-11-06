import AVFoundation
import AppKit
import Foundation
import RecastCore

/// `Recast --self-test FOLDER`: makes a tagged 24-bit test file in FOLDER, converts it to every format with the
/// built app and checks the results (bit-exact lossless audio, lengths, tags, cover art, loudness matching).
enum SelfTest {
    static func run(folder: URL?) -> Int32 {
        let folder = folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("Recast self-test \(UUID().uuidString.prefix(6))")
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        do {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let rate = 44100.0, frames = 88200
            let samples = (0..<2).map { channel in
                (0..<frames).map { index -> Float in
                    let t = Double(index) / rate
                    let value = 0.5 * sin(2 * .pi * (220 * t + 600 * t * t)) * (channel == 0 ? 1 : 0.6)
                    return Float((value * 8_388_608).rounded() / 8_388_608)
                }
            }
            let source = folder.appendingPathComponent("Self Test.wav")
            try writeWAV(samples, rate: rate, to: source)
            var tags = AudioTags()
            tags.title = "Self Test"
            tags.artist = "Recast"
            tags.album = "Checks"
            tags.track = 1
            tags.trackTotal = 9
            tags.artwork = Artwork(data: coverArt(), mimeType: "image/png")
            try TagIO.write(tags, to: source)

            for format in OutputFormat.allCases {
                var settings = ConversionSettings()
                settings.format = format
                let name = folder.appendingPathComponent("Self Test \(format.rawValue.uppercased())").appendingPathExtension(format.fileExtension)
                do {
                    let outcome = try Converter.convert(input: source, to: name, settings: settings)
                    let info = try AudioProbe.info(outcome.output)
                    expect(abs(info.duration - 2) < 0.06, "\(format.title): \(info.duration) s instead of 2 s")
                    let read = TagIO.read(outcome.output)
                    expect(read.title == "Self Test", "\(format.title): title not copied")
                    expect(read.track == 1, "\(format.title): track number not copied")
                    if format != .caf { expect(read.artwork?.data == tags.artwork?.data, "\(format.title): cover art not copied") }
                    if format.isLossless { expect(try decode(outcome.output) == samples, "\(format.title): audio isn't bit-exact") }
                    print("ok \(format.title): \(info.summary), \(outcome.bytes) bytes")
                } catch {
                    failures.append("\(format.title): \(error.localizedDescription)")
                }
            }

            var loud = ConversionSettings()
            loud.format = .mp3
            loud.volume = .loudness
            loud.loudnessTarget = -16
            let podcast = try Converter.convert(input: source, to: folder.appendingPathComponent("Self Test -16 LUFS.mp3"), settings: loud)
            let level = try AudioAnalysis.measure(podcast.output)
            expect(abs(level.loudness + 16) < 0.5, String(format: "loudness matching: %.2f LUFS instead of -16", level.loudness))
            print(String(format: "ok loudness: %.2f LUFS, true peak %.2f dBTP", level.loudness, level.truePeak))
        } catch {
            failures.append(error.localizedDescription)
        }
        if failures.isEmpty {
            print("Self-test passed (\(folder.path)).")
            return 0
        }
        print("Self-test FAILED:\n" + failures.map { "  \($0)" }.joined(separator: "\n"))
        return 1
    }

    private static func writeWAV(_ samples: [[Float]], rate: Double, to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: samples.count,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples[0].count))!
        buffer.frameLength = buffer.frameCapacity
        for (channel, values) in samples.enumerated() { buffer.floatChannelData![channel].update(from: values, count: values.count) }
        try file.write(from: buffer)
    }

    private static func decode(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let channels = Int(file.processingFormat.channelCount)
        var result = Array(repeating: [Float](), count: channels)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768)!
        while file.framePosition < file.length {
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            for channel in 0..<channels {
                result[channel] += UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength))
            }
        }
        return result
    }

    private static func coverArt() -> Data {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemIndigo.setFill()
            rect.fill()
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }
}
