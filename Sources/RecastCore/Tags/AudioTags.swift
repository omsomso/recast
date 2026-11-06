import Foundation

/// Cover art carried across conversions.
public struct Artwork: Equatable, Sendable {
    public var data: Data
    public var mimeType: String
    public var description: String

    public init(data: Data, mimeType: String? = nil, description: String = "") {
        self.data = data
        self.mimeType = mimeType ?? Artwork.sniffMIME(data)
        self.description = description
    }

    static func sniffMIME(_ data: Data) -> String {
        if data.count > 3, data[data.startIndex] == 0x89, data.hasPrefix("PNG", at: 1) { return "image/png" }
        if data.count > 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 { return "image/jpeg" }
        if data.hasPrefix("GIF8") { return "image/gif" }
        return "image/jpeg"
    }

    var isPNG: Bool { mimeType == "image/png" }
}

/// The common tags of a music file, independent of how a container stores them.
public struct AudioTags: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var composer: String?
    public var genre: String?
    /// The release date as written ("2024" or "2024-03-01").
    public var date: String?
    public var comment: String?
    public var lyrics: String?
    public var copyright: String?
    public var isrc: String?
    public var grouping: String?
    public var track: Int?
    public var trackTotal: Int?
    public var disc: Int?
    public var discTotal: Int?
    public var bpm: Int?
    public var compilation = false
    public var artwork: Artwork?
    /// Other text tags by upper-case Vorbis-style name, e.g. "REPLAYGAIN_TRACK_GAIN" or "MUSICBRAINZ_TRACKID".
    public var extra: [String: String] = [:]

    public init() {}

    public var isEmpty: Bool { self == AudioTags() }

    public var year: String? {
        guard let date, date.count >= 4 else { return date }
        return String(date.prefix(4))
    }

    /// Text fields that every container maps the same way, by their Vorbis comment names.
    static let textFields: [(String, WritableKeyPath<AudioTags, String?>)] = [
        ("TITLE", \.title), ("ARTIST", \.artist), ("ALBUM", \.album), ("ALBUMARTIST", \.albumArtist),
        ("COMPOSER", \.composer), ("GENRE", \.genre), ("DATE", \.date), ("COMMENT", \.comment),
        ("LYRICS", \.lyrics), ("COPYRIGHT", \.copyright), ("ISRC", \.isrc), ("GROUPING", \.grouping),
    ]

    /// Drops values that describe the old file rather than the music (loudness analysis when the level changed).
    public mutating func dropLevelInformation() {
        extra = extra.filter { !$0.key.hasPrefix("REPLAYGAIN_") && $0.key != "ITUNNORM" && $0.key != "R128_TRACK_GAIN" && $0.key != "R128_ALBUM_GAIN" }
    }

    /// Fills empty fields from another tag set (the first reader's values win).
    mutating func merge(_ other: AudioTags) {
        for (_, path) in AudioTags.textFields where self[keyPath: path] == nil { self[keyPath: path] = other[keyPath: path] }
        if track == nil { track = other.track }
        if trackTotal == nil { trackTotal = other.trackTotal }
        if disc == nil { disc = other.disc }
        if discTotal == nil { discTotal = other.discTotal }
        if bpm == nil { bpm = other.bpm }
        if !compilation { compilation = other.compilation }
        if artwork == nil { artwork = other.artwork }
        for (key, value) in other.extra where extra[key] == nil { extra[key] = value }
    }

    /// Parses "3" or "3/12".
    static func numberPair(_ text: String) -> (Int?, Int?) {
        let parts = text.split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return (parts.first.flatMap { Int($0) }, parts.count > 1 ? Int(parts[1]) : nil)
    }

    /// Cleans a value read from a file: trims NULs and whitespace, nil when empty.
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}").union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Sets a field from a Vorbis-style name. Used by every reader for names it doesn't map itself.
    mutating func set(vorbisName rawName: String, value rawValue: String) {
        let name = rawName.uppercased()
        guard let value = AudioTags.clean(rawValue) else { return }
        switch name {
        case "TRACKNUMBER":
            let (number, total) = AudioTags.numberPair(value)
            track = track ?? number
            if trackTotal == nil { trackTotal = total }
        case "TRACKTOTAL", "TOTALTRACKS": trackTotal = trackTotal ?? Int(value)
        case "DISCNUMBER":
            let (number, total) = AudioTags.numberPair(value)
            disc = disc ?? number
            if discTotal == nil { discTotal = total }
        case "DISCTOTAL", "TOTALDISCS": discTotal = discTotal ?? Int(value)
        case "BPM": bpm = bpm ?? Int(Double(value)?.rounded() ?? 0).nonZero
        case "COMPILATION": compilation = compilation || value == "1" || value.lowercased() == "true"
        case "ALBUM ARTIST", "ALBUM_ARTIST": if albumArtist == nil { albumArtist = value }
        case "YEAR": if date == nil { date = value }
        case "DESCRIPTION": if comment == nil { comment = value }
        case "UNSYNCEDLYRICS", "UNSYNCED LYRICS": if lyrics == nil { lyrics = value }
        case "CONTENTGROUP": if grouping == nil { grouping = value }
        // Describe the old encoding, not the music.
        case "ENCODER", "ENCODING", "ENCODED-BY", "ENCODEDBY", "ENCODER_OPTIONS", "ENCODERSETTINGS", "VENDOR", "WAVEFORMATEXTENSIBLE_CHANNEL_MASK",
             "ITUNSMPB", "ITUNES_CDDB_IDS", "ITUNES_CDDB_1", "ENCODING PARAMS", "LENGTH", "TLEN":
            break
        default:
            if let path = AudioTags.textFields.first(where: { $0.0 == name })?.1 {
                if self[keyPath: path] == nil { self[keyPath: path] = value }
            } else if extra[name] == nil {
                extra[name] = value
            }
        }
    }

    /// The tags as Vorbis comment fields, in a stable order.
    public func vorbisFields() -> [(String, String)] {
        var fields: [(String, String)] = []
        for (name, path) in AudioTags.textFields { if let value = self[keyPath: path] { fields.append((name, value)) } }
        if let track { fields.append(("TRACKNUMBER", String(track))) }
        if let trackTotal { fields.append(("TRACKTOTAL", String(trackTotal))) }
        if let disc { fields.append(("DISCNUMBER", String(disc))) }
        if let discTotal { fields.append(("DISCTOTAL", String(discTotal))) }
        if let bpm { fields.append(("BPM", String(bpm))) }
        if compilation { fields.append(("COMPILATION", "1")) }
        for key in extra.keys.sorted() { fields.append((key, extra[key]!)) }
        return fields
    }
}

extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

/// The 80 ID3v1 genres plus Winamp's extensions, for numeric genres in ID3 and MP4 files.
enum Genres {
    static let names = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal", "New Age", "Oldies",
        "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks",
        "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental",
        "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise", "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative",
        "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk",
        "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle",
        "Native American", "Cabaret", "New Wave", "Psychadelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal", "Acid Punk",
        "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock", "Folk", "Folk-Rock", "National Folk", "Swing",
        "Fast Fusion", "Bebob", "Latin", "Revival", "Celtic", "Bluegrass", "Avantgarde", "Gothic Rock", "Progressive Rock",
        "Psychedelic Rock", "Symphonic Rock", "Slow Rock", "Big Band", "Chorus", "Easy Listening", "Acoustic", "Humour", "Speech",
        "Chanson", "Opera", "Chamber Music", "Sonata", "Symphony", "Booty Bass", "Primus", "Porn Groove", "Satire", "Slow Jam",
        "Club", "Tango", "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle", "Duet", "Punk Rock",
        "Drum Solo", "A capella", "Euro-House", "Dance Hall",
    ]

    static func name(_ index: Int) -> String? { index >= 0 && index < names.count ? names[index] : nil }

    /// Resolves ID3's "(13)", "(13)Pop" and "13" forms.
    static func resolve(_ text: String) -> String {
        if text.hasPrefix("("), let close = text.firstIndex(of: ")"), let number = Int(text[text.index(after: text.startIndex)..<close]) {
            let rest = String(text[text.index(after: close)...])
            return rest.isEmpty ? (name(number) ?? text) : rest
        }
        if let number = Int(text), let known = name(number) { return known }
        return text
    }
}
