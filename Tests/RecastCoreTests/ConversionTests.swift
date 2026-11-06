import AVFoundation
import XCTest
@testable import RecastCore

final class ConversionTests: XCTestCase {
    override func setUp() { Fixtures.currentTest = self }

    /// A 24-bit stereo WAV with tags, the source most tests start from.
    private func taggedSource(_ folder: URL, rate: Double = 44100, seconds: Double = 2, bits: Int = 24) throws -> (URL, [[Float]]) {
        let samples = Fixtures.quantized(Fixtures.signal(frames: Int(rate * seconds), channels: 2, rate: rate), bits: bits)
        let url = folder.appendingPathComponent("source.wav")
        try Fixtures.writePCM(samples, rate: rate, bits: bits, to: url)
        try ChunkTags.writeWAV(Fixtures.tags, includeArtwork: true, to: url)
        return (url, samples)
    }

    func testLosslessFormatsAreBitExact() throws {
        let folder = try Fixtures.folder()
        let (source, samples) = try taggedSource(folder)
        for format in [OutputFormat.wav, .aiff, .flac, .alac, .caf] {
            let outcome = try Fixtures.convert(source, Fixtures.settings(format), name: "exact-\(format.rawValue)")
            let info = try AudioProbe.info(outcome.output)
            XCTAssertEqual(info.bitDepth, 24, "\(format)")
            XCTAssertEqual(info.sampleRate, 44100, "\(format)")
            let decoded = try Fixtures.read(outcome.output).samples
            XCTAssertEqual(decoded.count, 2, "\(format)")
            XCTAssertEqual(decoded[0].count, samples[0].count, "\(format) length")
            XCTAssertEqual(decoded, samples, "\(format) samples differ")
            XCTAssertFalse(outcome.notes.contains { $0.contains("Dithered") }, "\(format) shouldn't dither an unchanged file")
        }
    }

    func testVeryShortFilesInEveryFormat() throws {
        let folder = try Fixtures.folder()
        for frames in [0, 1, 300, 4607, 4608, 4609] {
            let samples = Fixtures.quantized(Fixtures.signal(frames: frames, channels: 2, rate: 44100), bits: 24)
            let source = folder.appendingPathComponent("short-\(frames).wav")
            try Fixtures.writePCM(samples, rate: 44100, bits: 24, to: source)
            try ChunkTags.writeWAV(Fixtures.tags, includeArtwork: true, to: source)
            for format in OutputFormat.allCases {
                let outcome = try Fixtures.convert(source, Fixtures.settings(format), name: "short-\(frames)-\(format.rawValue)")
                // FLAC files under 16 samples are valid, but Core Audio can't open them to check.
                if format == .flac, frames < 16 { continue }
                if format.isLossless, frames > 0 {
                    XCTAssertEqual(try Fixtures.read(outcome.output).samples, samples, "\(frames) frames as \(format)")
                } else {
                    XCTAssertNoThrow(try AudioProbe.info(outcome.output), "\(frames) frames as \(format)")
                }
                XCTAssertEqual(TagIO.read(outcome.output).title, Fixtures.tags.title, "\(frames) frames as \(format)")
            }
        }
    }

    func testSixteenBitSourceStaysExact() throws {
        let folder = try Fixtures.folder()
        let samples = Fixtures.quantized(Fixtures.signal(frames: 44100, channels: 2, rate: 44100), bits: 16)
        let source = folder.appendingPathComponent("cd.wav")
        try Fixtures.writePCM(samples, rate: 44100, bits: 16, to: source)
        let flac = try Fixtures.convert(source, Fixtures.settings(.flac))
        XCTAssertEqual(try AudioProbe.info(flac.output).bitDepth, 16)
        XCTAssertEqual(try Fixtures.read(flac.output).samples, samples)
        let back = try Fixtures.convert(flac.output, Fixtures.settings(.wav), name: "cd-back")
        XCTAssertEqual(try Fixtures.read(back.output).samples, samples)
    }

    func testDitherTo16Bit() throws {
        let folder = try Fixtures.folder()
        let (source, samples) = try taggedSource(folder)
        let lsb = 1.0 / 32768
        let dithered = try Fixtures.convert(source, Fixtures.settings(.wav) { $0.pcmDepth = .int16 }, name: "dithered")
        XCTAssertTrue(dithered.notes.contains { $0.contains("Dithered to 16-bit") })
        let ditheredError = Fixtures.rms(zip(try Fixtures.read(dithered.output).samples[0], samples[0]).map { $0 - $1 }) / lsb
        // Rounding plus triangular dither: 0.5 LSB RMS.
        XCTAssertEqual(ditheredError, 0.5, accuracy: 0.08)

        let plain = try Fixtures.convert(source, Fixtures.settings(.wav) { $0.pcmDepth = .int16; $0.dither = false }, name: "plain")
        let plainError = Fixtures.rms(zip(try Fixtures.read(plain.output).samples[0], samples[0]).map { $0 - $1 }) / lsb
        // Rounding only: 1/sqrt(12) LSB RMS.
        XCTAssertEqual(plainError, 0.289, accuracy: 0.05)

        let shaped = try Fixtures.convert(source, Fixtures.settings(.wav) { $0.pcmDepth = .int16; $0.noiseShaping = true }, name: "shaped")
        XCTAssertTrue(shaped.notes.contains { $0.contains("noise shaping") })
        XCTAssertGreaterThan(Fixtures.rms(zip(try Fixtures.read(shaped.output).samples[0], samples[0]).map { $0 - $1 }) / lsb, ditheredError)
    }

    func testCompressedFormatsSoundLikeTheSource() throws {
        let folder = try Fixtures.folder()
        let (source, samples) = try taggedSource(folder, seconds: 3)
        let cases: [(OutputFormat, ConversionSettings, Double)] = [
            (.mp3, Fixtures.settings(.mp3), 0.98),
            (.mp3, Fixtures.settings(.mp3) { $0.mp3Mode = .vbr; $0.mp3VBRQuality = 2 }, 0.97),
            (.aac, Fixtures.settings(.aac), 0.98),
            (.aac, Fixtures.settings(.aac) { $0.aacMode = .vbr }, 0.97),
            (.vorbis, Fixtures.settings(.vorbis), 0.97),
            (.opus, Fixtures.settings(.opus), 0.97),
        ]
        for (index, (format, settings, minimum)) in cases.enumerated() {
            let outcome = try Fixtures.convert(source, settings, name: "lossy-\(index)")
            let (decoded, rate) = try Fixtures.read(outcome.output)
            XCTAssertEqual(decoded.count, 2, "\(format)")
            let expectedRate = format == .opus ? 48000.0 : 44100
            XCTAssertEqual(rate, expectedRate, "\(format)")
            let reference = format == .opus ? try Fixtures.read(Fixtures.convert(source, Fixtures.settings(.wav) { $0.sampleRate = 48000; $0.pcmDepth = .float32 }, name: "ref48").output).samples : samples
            let duration = Double(decoded[0].count) / rate, expected = Double(samples[0].count) / 44100
            XCTAssertEqual(duration, expected, accuracy: 0.06, "\(format) duration")
            let (lag, correlation) = Fixtures.alignment(reference[0], decoded[0])
            XCTAssertGreaterThan(correlation, minimum, "\(format) #\(index) correlation (lag \(lag))")
            // Gapless: no added delay where the container records the encoder's priming.
            if format == .aac || format == .opus { XCTAssertLessThanOrEqual(abs(lag), 2, "\(format) is offset by \(lag) samples") }
            print("\(format) #\(index): lag \(lag), correlation \(correlation), \(outcome.bytes) bytes")
        }
    }

    func testResampling() throws {
        let folder = try Fixtures.folder()
        let samples = Fixtures.sine(frequency: 1000, frames: 44100, rate: 44100, amplitude: 0.5)
        let source = folder.appendingPathComponent("sine.wav")
        try Fixtures.writePCM(samples, rate: 44100, bits: 32, float: true, to: source)
        let outcome = try Fixtures.convert(source, Fixtures.settings(.wav) { $0.sampleRate = 48000; $0.pcmDepth = .float32 })
        let (decoded, rate) = try Fixtures.read(outcome.output)
        XCTAssertEqual(rate, 48000)
        XCTAssertEqual(Double(decoded[0].count), 48000, accuracy: 64)
        let middle = Array(decoded[0][4800..<43200])
        XCTAssertEqual(Fixtures.rms(middle), 0.5 / sqrt(2), accuracy: 0.003)
        var crossings = 0
        for index in 1..<middle.count where (middle[index - 1] < 0) != (middle[index] < 0) { crossings += 1 }
        XCTAssertEqual(Double(crossings) / (Double(middle.count) / 48000), 2000, accuracy: 10)

        // MP3 tops out at 48 kHz: a 96 kHz source is resampled, with a note.
        let high = folder.appendingPathComponent("high.wav")
        try Fixtures.writePCM(Fixtures.sine(frequency: 1000, frames: 9600, rate: 96000, amplitude: 0.5), rate: 96000, bits: 24, to: high)
        let mp3 = try Fixtures.convert(high, Fixtures.settings(.mp3))
        XCTAssertEqual(try AudioProbe.info(mp3.output).sampleRate, 48000)
        XCTAssertTrue(mp3.notes.contains { $0.contains("Resampled to 48 kHz") })
    }

    func testChannelMixing() throws {
        let folder = try Fixtures.folder()
        let left = Fixtures.sine(frequency: 500, frames: 22050, rate: 44100, amplitude: 0.6, channels: 1)[0]
        let silent = [Float](repeating: 0, count: left.count)
        let source = folder.appendingPathComponent("left.wav")
        try Fixtures.writePCM([left, silent], rate: 44100, bits: 32, float: true, to: source)
        let mono = try Fixtures.read(Fixtures.convert(source, Fixtures.settings(.wav) { $0.channels = .mono; $0.pcmDepth = .float32 }).output).samples
        XCTAssertEqual(mono.count, 1)
        XCTAssertEqual(mono[0].count, left.count)
        XCTAssertLessThan(zip(mono[0], left).map { abs($0 - $1 * 0.5) }.max()!, 1e-6)

        let monoSource = folder.appendingPathComponent("mono.wav")
        try Fixtures.writePCM([left], rate: 44100, bits: 32, float: true, to: monoSource)
        let stereo = try Fixtures.read(Fixtures.convert(monoSource, Fixtures.settings(.wav) { $0.channels = .stereo; $0.pcmDepth = .float32 }).output).samples
        XCTAssertEqual(stereo.count, 2)
        XCTAssertLessThan(zip(stereo[0], left).map { abs($0 - $1) }.max()!, 1e-6)
        XCTAssertLessThan(zip(stereo[1], left).map { abs($0 - $1) }.max()!, 1e-6)

        // Six channels into MP3: mixed to stereo with a note.
        let surround = folder.appendingPathComponent("surround.wav")
        try Fixtures.writePCM(Array(repeating: Array(left.prefix(8820)), count: 6), rate: 44100, bits: 24, to: surround)
        let mp3 = try Fixtures.convert(surround, Fixtures.settings(.mp3))
        XCTAssertEqual(try AudioProbe.info(mp3.output).channels, 2)
        XCTAssertTrue(mp3.notes.contains { $0.contains("Mixed down to stereo") })
    }

    func testLoudnessMeasurementAndNormalization() throws {
        let folder = try Fixtures.folder()
        // A 997 Hz sine at -20 dBFS on both channels measures -20 LUFS (BS.1770 reference).
        let amplitude = Float(pow(10, -20.0 / 20))
        let samples = Fixtures.sine(frequency: 997, frames: 48000 * 5, rate: 48000, amplitude: amplitude)
        let meter = LoudnessMeter(channels: 2, sampleRate: 48000)
        let buffer = AVAudioPCMBuffer(pcmFormat: floatFormat(rate: 48000, channels: 2), frameCapacity: AVAudioFrameCount(samples[0].count))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 { buffer.floatChannelData![channel].update(from: samples[channel], count: samples[channel].count) }
        meter.process(buffer)
        XCTAssertEqual(meter.integratedLoudness, -20, accuracy: 0.1)
        XCTAssertEqual(LoudnessMeter.decibels(meter.truePeak), -20, accuracy: 0.1)

        let source = folder.appendingPathComponent("tone.wav")
        try Fixtures.writePCM(samples, rate: 48000, bits: 32, float: true, to: source)
        let louder = try Fixtures.convert(source, Fixtures.settings(.wav) { $0.volume = .loudness; $0.loudnessTarget = -14; $0.pcmDepth = .float32 }, name: "loud")
        XCTAssertTrue(louder.notes.contains { $0.contains("Loudness set to -14.0 LUFS") }, "\(louder.notes)")
        XCTAssertEqual(Double(Fixtures.peak(try Fixtures.read(louder.output).samples)), Double(amplitude) * pow(10, 6.0 / 20), accuracy: 0.002)

        // A target the true-peak ceiling can't allow stops at the ceiling.
        let capped = try Fixtures.convert(source, Fixtures.settings(.wav) { $0.volume = .loudness; $0.loudnessTarget = 0; $0.truePeakCeiling = -1; $0.pcmDepth = .float32 }, name: "capped")
        XCTAssertTrue(capped.notes.contains { $0.contains("instead of 0.0") }, "\(capped.notes)")
        XCTAssertEqual(LoudnessMeter.decibels(Fixtures.peak(try Fixtures.read(capped.output).samples)), -1, accuracy: 0.05)

        let peaked = try Fixtures.convert(source, Fixtures.settings(.flac) { $0.volume = .peak; $0.peakTarget = -1 }, name: "peak")
        XCTAssertEqual(LoudnessMeter.decibels(Fixtures.peak(try Fixtures.read(peaked.output).samples)), -1, accuracy: 0.01)
    }

    func testClippingIsReported() throws {
        let folder = try Fixtures.folder()
        let source = folder.appendingPathComponent("hot.wav")
        try Fixtures.writePCM(Fixtures.sine(frequency: 440, frames: 4410, rate: 44100, amplitude: 0.5), rate: 44100, bits: 24, to: source)
        let outcome = try Fixtures.convert(source, Fixtures.settings(.wav) { $0.volume = .gain; $0.gainDB = 12; $0.pcmDepth = .int16 })
        XCTAssertTrue(outcome.notes.contains { $0.contains("clipped") }, "\(outcome.notes)")
        XCTAssertLessThanOrEqual(Fixtures.peak(try Fixtures.read(outcome.output).samples), 1)
    }

    func testTagsCarryAcrossFormats() throws {
        let folder = try Fixtures.folder()
        let (source, _) = try taggedSource(folder, seconds: 1)
        let expected = Fixtures.tags
        XCTAssertEqual(TagIO.read(source).title, expected.title, "WAV fixture tags")
        for format in OutputFormat.allCases {
            let outcome = try Fixtures.convert(source, Fixtures.settings(format), name: "tags-\(format.rawValue)")
            let tags = TagIO.read(outcome.output)
            XCTAssertEqual(tags.title, expected.title, "\(format) title")
            XCTAssertEqual(tags.artist, expected.artist, "\(format) artist")
            XCTAssertEqual(tags.album, expected.album, "\(format) album")
            XCTAssertEqual(tags.year, "2024", "\(format) year")
            XCTAssertEqual(tags.track, 3, "\(format) track")
            XCTAssertEqual(tags.genre, expected.genre, "\(format) genre")
            guard format != .caf else {
                XCTAssertTrue(outcome.notes.contains { $0.contains("cover art") })
                continue
            }
            XCTAssertEqual(tags.albumArtist, expected.albumArtist, "\(format) album artist")
            XCTAssertEqual(tags.composer, expected.composer, "\(format) composer")
            XCTAssertEqual(tags.comment, expected.comment, "\(format) comment")
            XCTAssertEqual(tags.trackTotal, 12, "\(format) track total")
            XCTAssertEqual(tags.disc, 1, "\(format) disc")
            XCTAssertEqual(tags.discTotal, 2, "\(format) disc total")
            XCTAssertEqual(tags.bpm, 120, "\(format) bpm")
            XCTAssertTrue(tags.compilation, "\(format) compilation")
            XCTAssertEqual(tags.extra["MUSICBRAINZ_TRACKID"], "abc-123", "\(format) extra")
            XCTAssertEqual(tags.artwork?.data, expected.artwork?.data, "\(format) artwork")
        }
        // Without tags.
        let bare = try Fixtures.convert(source, Fixtures.settings(.mp3) { $0.copyTags = false }, name: "bare")
        XCTAssertTrue(TagIO.read(bare.output).isEmpty)
    }

    func testLargeArtworkMovesM4AAudio() throws {
        let folder = try Fixtures.folder()
        let (source, samples) = try taggedSource(folder, seconds: 1)
        var tags = TagIO.read(source)
        // Bigger than the padding Core Audio leaves, so the audio data has to move and chunk offsets shift.
        tags.artwork = Artwork(data: Fixtures.artwork + Data(count: 300_000), mimeType: "image/png")
        let output = folder.appendingPathComponent("big.m4a")
        _ = try Converter.convert(input: source, to: output, settings: Fixtures.settings(.alac) { $0.copyTags = false })
        try MP4Tags.write(tags, includeArtwork: true, to: output)
        XCTAssertEqual(try Fixtures.read(output).samples, samples)
        XCTAssertEqual(TagIO.read(output).artwork?.data.count, tags.artwork?.data.count)
        XCTAssertEqual(TagIO.read(output).title, tags.title)
    }

    func testNeverWritesOverTheOriginal() throws {
        let folder = try Fixtures.folder()
        let (source, _) = try taggedSource(folder, seconds: 0.5)
        XCTAssertThrowsError(try Converter.convert(input: source, to: source, settings: Fixtures.settings(.wav))) { error in
            XCTAssertEqual(error as? ConversionError, .wouldReplaceOriginal)
        }
        let planned = OutputPlanner.plannedURL(for: source, sourceRoot: nil, settings: Fixtures.settings(.wav), tags: AudioTags())
        XCTAssertEqual(planned, source)
        XCTAssertEqual(OutputPlanner.resolve(planned, input: source, policy: .replace, taken: []),
                       .write(folder.appendingPathComponent("source 2.wav")))
    }
}
