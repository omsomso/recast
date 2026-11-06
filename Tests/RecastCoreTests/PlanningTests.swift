import XCTest
@testable import RecastCore

final class PlanningTests: XCTestCase {
    override func setUp() { Fixtures.currentTest = self }

    func testNamePattern() {
        var tags = AudioTags()
        tags.title = "Song: Part 1/2"
        tags.artist = "Band"
        tags.track = 4
        let input = URL(fileURLWithPath: "/tmp/in/track.flac")
        XCTAssertEqual(OutputPlanner.fileName(pattern: "{name}", input: input, tags: tags, format: .mp3), "track")
        XCTAssertEqual(OutputPlanner.fileName(pattern: "{track} {artist} - {title}", input: input, tags: tags, format: .mp3), "04 Band - Song- Part 1-2")
        XCTAssertEqual(OutputPlanner.fileName(pattern: "{year} {name} ({format})", input: input, tags: tags, format: .aac), "track (AAC)")
        XCTAssertEqual(OutputPlanner.fileName(pattern: "", input: input, tags: tags, format: .mp3), "track")
        XCTAssertEqual(OutputPlanner.fileName(pattern: "{year}", input: input, tags: tags, format: .mp3), "track")
    }

    func testDestinationsAndFolderStructure() {
        var settings = ConversionSettings()
        settings.format = .mp3
        let root = URL(fileURLWithPath: "/Music/Album", isDirectory: true)
        let input = URL(fileURLWithPath: "/Music/Album/CD1/01.wav")
        XCTAssertEqual(OutputPlanner.plannedURL(for: input, sourceRoot: root, settings: settings, tags: AudioTags()).path, "/Music/Album/CD1/01.mp3")
        settings.destination = .folder
        settings.folderPath = "/Out"
        XCTAssertEqual(OutputPlanner.plannedURL(for: input, sourceRoot: root, settings: settings, tags: AudioTags()).path, "/Out/Album/CD1/01.mp3")
        XCTAssertEqual(OutputPlanner.plannedURL(for: input, sourceRoot: nil, settings: settings, tags: AudioTags()).path, "/Out/01.mp3")
        settings.keepFolderStructure = false
        XCTAssertEqual(OutputPlanner.plannedURL(for: input, sourceRoot: root, settings: settings, tags: AudioTags()).path, "/Out/01.mp3")
    }

    func testCollisions() throws {
        let folder = try Fixtures.folder()
        let existing = folder.appendingPathComponent("song.mp3")
        FileManager.default.createFile(atPath: existing.path, contents: Data([1]))
        let input = folder.appendingPathComponent("song.wav")
        XCTAssertEqual(OutputPlanner.resolve(existing, input: input, policy: .keepBoth, taken: []), .write(folder.appendingPathComponent("song 2.mp3")))
        XCTAssertEqual(OutputPlanner.resolve(existing, input: input, policy: .replace, taken: []), .write(existing))
        XCTAssertEqual(OutputPlanner.resolve(existing, input: input, policy: .skip, taken: []), .skip(existing))
        // Another file in the same batch already claimed "song 2.mp3".
        let taken: Set<String> = [OutputPlanner.pathKey(folder.appendingPathComponent("song 2.mp3"))]
        XCTAssertEqual(OutputPlanner.resolve(existing, input: input, policy: .keepBoth, taken: taken), .write(folder.appendingPathComponent("song 3.mp3")))
        // A path claimed in the batch is never replaced, whatever the policy.
        let fresh = folder.appendingPathComponent("other.mp3")
        XCTAssertEqual(OutputPlanner.resolve(fresh, input: input, policy: .replace, taken: [OutputPlanner.pathKey(fresh)]),
                       .write(folder.appendingPathComponent("other 2.mp3")))
    }

    func testScannerFindsAudioInFolders() throws {
        let folder = try Fixtures.folder()
        let album = folder.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: album.appendingPathComponent("Disc 2"), withIntermediateDirectories: true)
        for name in ["10.wav", "2.flac", "cover.jpg", "Disc 2/1.mp3", ".hidden.wav"] {
            FileManager.default.createFile(atPath: album.appendingPathComponent(name).path, contents: Data())
        }
        let found = AudioFileScanner.scan([album])
        XCTAssertEqual(Set(found.map { $0.url.lastPathComponent }), ["10.wav", "2.flac", "1.mp3"])
        XCTAssertTrue(found.allSatisfy { $0.root == album })
        XCTAssertEqual(found.firstIndex { $0.url.lastPathComponent == "2.flac" }! < found.firstIndex { $0.url.lastPathComponent == "10.wav" }!, true)
    }

    func testSupportedRates() {
        XCTAssertEqual(OutputFormat.mp3.supportedRate(for: 96000), 48000)
        XCTAssertEqual(OutputFormat.mp3.supportedRate(for: 88200), 44100)
        XCTAssertEqual(OutputFormat.mp3.supportedRate(for: 44100), 44100)
        XCTAssertEqual(OutputFormat.opus.supportedRate(for: 44100), 48000)
        XCTAssertEqual(OutputFormat.flac.supportedRate(for: 96000), 96000)
        XCTAssertEqual(OutputFormat.aac.supportedRate(for: 7000), 8000)
    }

    func testSettingsDecodeKeepsDefaults() throws {
        let partial = #"{"format": "flac", "mp3Bitrate": 192, "channels": "nonsense", "unknownKey": 1}"#
        let settings = ConversionSettings.decode(Data(partial.utf8))
        XCTAssertEqual(settings.format, .flac)
        XCTAssertEqual(settings.mp3Bitrate, 192)
        XCTAssertEqual(settings.channels, .keep)
        XCTAssertEqual(settings.loudnessTarget, -14)
        var full = ConversionSettings()
        full.format = .opus
        full.opusBitrate = 96
        full.sampleRate = 48000
        XCTAssertEqual(ConversionSettings.decode(try JSONEncoder().encode(full)), full)
    }

    func testPresetsKeepOutputLocation() {
        var current = ConversionSettings()
        current.destination = .folder
        current.folderPath = "/Out"
        let podcast = Preset.builtIn.first { $0.name.hasPrefix("Podcast") }!
        let applied = current.applying(preset: podcast.settings)
        XCTAssertEqual(applied.format, .mp3)
        XCTAssertEqual(applied.channels, .mono)
        XCTAssertEqual(applied.folderPath, "/Out")
        XCTAssertEqual(applied.destination, .folder)
    }

    func testQualityChoicesMatchTheirSettings() {
        for format in OutputFormat.allCases {
            var settings = ConversionSettings()
            settings.format = format
            for choice in format.qualityChoices {
                let applied = choice.applied(to: settings)
                XCTAssertTrue(choice.isSelected(in: applied), "\(format) \(choice.title)")
                XCTAssertEqual(format.qualityChoices.filter { $0.isSelected(in: applied) }.count, 1, "\(format) \(choice.title) is ambiguous")
            }
        }
    }
}
