import Foundation

/// Decides where each converted file goes and what it is called.
public enum OutputPlanner {
    public enum Resolution: Equatable, Sendable {
        case write(URL)
        case skip(URL)
    }

    /// Tokens for the file name pattern.
    public static let tokens: [(token: String, title: String)] = [
        ("{name}", "Original name"), ("{title}", "Title"), ("{artist}", "Artist"), ("{album}", "Album"),
        ("{track}", "Track number"), ("{year}", "Year"), ("{format}", "Format"),
    ]

    /// Where a file would go before checking for existing files. `sourceRoot` is the folder the file was dropped
    /// with (nil for files dropped on their own); with "keep folder structure" its layout is recreated.
    public static func plannedURL(for input: URL, sourceRoot: URL?, settings: ConversionSettings, tags: AudioTags) -> URL {
        var directory = input.deletingLastPathComponent()
        if settings.destination == .folder, let path = settings.folderPath {
            directory = URL(fileURLWithPath: path, isDirectory: true)
            if settings.keepFolderStructure, let sourceRoot {
                let rootParent = sourceRoot.deletingLastPathComponent().standardizedFileURL.path
                let parent = input.deletingLastPathComponent().standardizedFileURL.path
                if parent.hasPrefix(rootParent) {
                    let relative = parent.dropFirst(rootParent.count).split(separator: "/").map(String.init)
                    for component in relative { directory.appendPathComponent(component, isDirectory: true) }
                }
            }
        }
        let name = fileName(pattern: settings.namePattern, input: input, tags: tags, format: settings.format)
        return directory.appendingPathComponent(name).appendingPathExtension(settings.format.fileExtension)
    }

    public static func fileName(pattern: String, input: URL, tags: AudioTags, format: OutputFormat) -> String {
        let original = input.deletingPathExtension().lastPathComponent
        var name = pattern.isEmpty ? "{name}" : pattern
        let values: [String: String] = [
            "{name}": original,
            "{title}": tags.title ?? original,
            "{artist}": tags.artist ?? "Unknown Artist",
            "{album}": tags.album ?? "Unknown Album",
            "{track}": tags.track.map { String(format: "%02d", $0) } ?? "",
            "{year}": tags.year ?? "",
            "{format}": format.title,
        ]
        for (token, value) in values { name = name.replacingOccurrences(of: token, with: value) }
        // No path separators or leading dots; collapse what empty tokens leave behind.
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " .-_").union(.whitespaces))
        while name.contains("  ") { name = name.replacingOccurrences(of: "  ", with: " ") }
        return name.isEmpty ? original : name
    }

    /// Applies the collision policy. `taken` holds paths already claimed in this batch (other outputs and every
    /// input), which are never written over.
    public static func resolve(_ planned: URL, input: URL, policy: CollisionPolicy, taken: Set<String>) -> Resolution {
        let key = pathKey(planned)
        let isOriginal = samePath(planned, input)
        let claimed = taken.contains(key)
        let exists = FileManager.default.fileExists(atPath: planned.path)
        if !exists && !claimed && !isOriginal { return .write(planned) }
        if isOriginal || claimed { return .write(uniqueURL(planned, taken: taken)) }
        switch policy {
        case .replace: return .write(planned)
        case .skip: return .skip(planned)
        case .keepBoth: return .write(uniqueURL(planned, taken: taken))
        }
    }

    /// "Song.mp3" → "Song 2.mp3", "Song 3.mp3"… as the Finder does.
    static func uniqueURL(_ url: URL, taken: Set<String>) -> URL {
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var number = 2
        while true {
            let candidate = directory.appendingPathComponent("\(base) \(number)").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path), !taken.contains(pathKey(candidate)) { return candidate }
            number += 1
        }
    }

    /// Paths compare case-insensitively, as on the default macOS volume format.
    public static func pathKey(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased() }

    public static func samePath(_ a: URL, _ b: URL) -> Bool { pathKey(a) == pathKey(b) }
}

/// Finds audio files in dropped items.
public enum AudioFileScanner {
    public struct Found: Sendable, Equatable {
        public var url: URL
        /// The dropped folder this file was found in, if any.
        public var root: URL?
    }

    public static func scan(_ urls: [URL]) -> [Found] {
        var found: [Found] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
                var inFolder: [URL] = []
                while let item = enumerator?.nextObject() as? URL {
                    if AudioProbe.audioExtensions.contains(item.pathExtension.lowercased()) { inFolder.append(item) }
                }
                inFolder.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                found += inFolder.map { Found(url: $0, root: url) }
            } else {
                found.append(Found(url: url, root: nil))
            }
        }
        return found
    }
}
