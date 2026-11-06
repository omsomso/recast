import XCTest
@testable import RecastCore

final class TagTests: XCTestCase {
    override func setUp() { Fixtures.currentTest = self }

    func testID3RoundTripBothVersions() {
        for version: UInt8 in [3, 4] {
            let tag = ID3.makeTag(Fixtures.tags, version: version, includeArtwork: true)
            XCTAssertEqual(ID3.tagSize(header: tag), tag.count)
            var read = ID3.read(tag)
            read.date = read.year
            XCTAssertEqual(read, Fixtures.tags, "ID3v2.\(version)")
        }
    }

    func testID3LegacyForms() {
        // ID3v2.2 with a numeric genre and a v2.2 picture frame.
        var frames = Data()
        func frame(_ id: String, _ payload: Data) {
            var writer = ByteWriter()
            writer.ascii(id)
            writer.u24be(UInt32(payload.count))
            writer.append(payload)
            frames.append(writer.data)
        }
        frame("TT2", Data([0]) + Data("Old Title".utf8))
        frame("TCO", Data([0]) + Data("(17)".utf8))
        frame("TRK", Data([0]) + Data("5/9".utf8))
        frame("PIC", Data([0]) + Data("PNG".utf8) + Data([3, 0]) + Fixtures.artwork)
        var header = ByteWriter()
        header.ascii("ID3")
        header.u8(2); header.u8(0); header.u8(0)
        header.u32be(ID3.toSyncsafe(frames.count))
        let tags = ID3.read(header.data + frames)
        XCTAssertEqual(tags.title, "Old Title")
        XCTAssertEqual(tags.genre, "Rock")
        XCTAssertEqual(tags.track, 5)
        XCTAssertEqual(tags.trackTotal, 9)
        XCTAssertEqual(tags.artwork?.mimeType, "image/png")

        var v1 = Data("TAG".utf8)
        for field in ["Title", "Artist", "Album"] { v1 += Data(field.utf8) + Data(count: 30 - field.count) }
        v1 += Data("1999".utf8) + Data(count: 28) + Data([0, 7, 8])
        let old = ID3.readV1(v1)
        XCTAssertEqual(old.title, "Title")
        XCTAssertEqual(old.date, "1999")
        XCTAssertEqual(old.track, 7)
        XCTAssertEqual(old.genre, "Jazz")
    }

    func testVorbisCommentRoundTrip() {
        let block = VorbisComment.make(Fixtures.tags, vendor: "test", artworkField: true)
        let (tags, vendor) = VorbisComment.read(block)
        XCTAssertEqual(vendor, "test")
        XCTAssertEqual(tags, Fixtures.tags)
    }

    func testLevelInformationIsDroppedWhenTheLevelChanges() throws {
        let folder = try Fixtures.folder()
        let source = folder.appendingPathComponent("gain.wav")
        try Fixtures.writePCM(Fixtures.sine(frequency: 440, frames: 4410, rate: 44100, amplitude: 0.25), rate: 44100, bits: 24, to: source)
        var tags = AudioTags()
        tags.title = "Level"
        tags.extra["REPLAYGAIN_TRACK_GAIN"] = "-3.2 dB"
        try ChunkTags.writeWAV(tags, includeArtwork: false, to: source)
        let kept = try Fixtures.convert(source, Fixtures.settings(.flac), name: "kept")
        XCTAssertEqual(TagIO.read(kept.output).extra["REPLAYGAIN_TRACK_GAIN"], "-3.2 dB")
        let changed = try Fixtures.convert(source, Fixtures.settings(.flac) { $0.volume = .gain; $0.gainDB = 3 }, name: "changed")
        XCTAssertNil(TagIO.read(changed.output).extra["REPLAYGAIN_TRACK_GAIN"])
        XCTAssertEqual(TagIO.read(changed.output).title, "Level")
    }
}
