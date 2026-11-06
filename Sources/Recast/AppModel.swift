import AppKit
import Observation
import RecastCore
import SwiftUI
import UniformTypeIdentifiers

@Observable @MainActor
final class AppModel {
    static let shared = AppModel()

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        /// The dropped folder the file came from, for "keep folder structure".
        let root: URL?
        var info: AudioFileInfo?
        var tags: AudioTags?
        var state: State = .reading
        var progress: Double = 0
        var output: URL?
        var outputBytes: Int64 = 0
        var notes: [String] = []

        var isBusy: Bool { state == .queued || state == .converting }
    }

    enum State: Equatable {
        case reading, ready, unreadable(String), queued, converting, done, skipped(String), failed(String)
    }

    struct Summary: Equatable {
        var converted = 0
        var skipped = 0
        var failed = 0
        var stopped = false
        var outputs: [URL] = []
    }

    var items: [Item] = []
    var settings: ConversionSettings { didSet { if settings != oldValue { save() } } }
    var userPresets: [Preset] { didSet { savePresets() } }
    var recentFolders: [String] { didSet { UserDefaults.standard.set(recentFolders, forKey: "recentFolders") } }
    var isConverting = false
    var showInspector: Bool { didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") } }
    var summary: Summary?
    var namingPreset = false

    private var cancellation = Cancellation()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Recast conversions"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        return queue
    }()

    init() {
        let defaults = UserDefaults.standard
        settings = defaults.data(forKey: "settings").map(ConversionSettings.decode) ?? ConversionSettings()
        userPresets = (defaults.data(forKey: "presets")).flatMap { try? JSONDecoder().decode([Preset].self, from: $0) } ?? []
        recentFolders = defaults.stringArray(forKey: "recentFolders") ?? []
        showInspector = defaults.bool(forKey: "showInspector")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "settings") }
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(userPresets) { UserDefaults.standard.set(data, forKey: "presets") }
    }

    // MARK: Files

    var convertibleCount: Int { items.filter { $0.info != nil && !$0.isBusy }.count }
    var isReading: Bool { items.contains { $0.state == .reading } }
    var totalDuration: Double { items.compactMap { $0.info?.duration }.reduce(0, +) }

    func add(_ urls: [URL]) {
        let known = Set(items.map { OutputPlanner.pathKey($0.url) })
        Task.detached(priority: .userInitiated) {
            let found = AudioFileScanner.scan(urls)
            var seen = known
            let fresh = found.filter { seen.insert(OutputPlanner.pathKey($0.url)).inserted }
            let ids = await MainActor.run {
                self.summary = nil
                let added = fresh.map { Item(url: $0.url, root: $0.root) }
                self.items += added
                return added.map(\.id)
            }
            for (id, file) in zip(ids, fresh) {
                let result: Result<(AudioFileInfo, AudioTags), Error> = Result { (try AudioProbe.info(file.url), TagIO.read(file.url)) }
                await MainActor.run {
                    guard let index = self.items.firstIndex(where: { $0.id == id }) else { return }
                    switch result {
                    case .success(let (info, tags)):
                        self.items[index].info = info
                        self.items[index].tags = tags
                        self.items[index].state = .ready
                    case .failure(let error):
                        self.items[index].state = .unreadable(error.localizedDescription)
                    }
                }
            }
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.audio, .folder] + AudioProbe.audioExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose audio files or folders to convert."
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func remove(_ id: Item.ID) {
        items.removeAll { $0.id == id && !$0.isBusy }
        if items.isEmpty { summary = nil }
    }

    func removeFinished() {
        items.removeAll { item in
            if case .skipped = item.state { return true }
            return item.state == .done
        }
        summary = nil
    }

    func clear() {
        guard !isConverting else { return }
        items.removeAll()
        summary = nil
    }

    // MARK: Output folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where converted files go."
        if let path = settings.folderPath { panel.directoryURL = URL(fileURLWithPath: path) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useFolder(url.path)
    }

    func useFolder(_ path: String) {
        settings.folderPath = path
        settings.destination = .folder
        recentFolders = ([path] + recentFolders.filter { $0 != path }).prefix(4).map { $0 }
    }

    var destinationTitle: String {
        guard settings.destination == .folder, let path = settings.folderPath else { return "Next to Originals" }
        return FileManager.default.displayName(atPath: path)
    }

    // MARK: Presets

    func apply(_ preset: Preset) { settings = settings.applying(preset: preset.settings) }

    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        userPresets.removeAll { $0.name == trimmed }
        userPresets.append(Preset(name: trimmed, settings: settings))
    }

    func deletePreset(_ preset: Preset) { userPresets.removeAll { $0.id == preset.id } }

    func isCurrent(_ preset: Preset) -> Bool { settings.presetValue() == preset.settings }

    // MARK: Converting

    func convert() {
        guard !isConverting else { return }
        let settings = self.settings
        if settings.destination == .folder, settings.folderPath == nil {
            chooseFolder()
            guard self.settings.folderPath != nil else { return }
            return convert()
        }
        // Claim every output first so files in this batch never collide with each other or with an input.
        var taken = Set(items.map { OutputPlanner.pathKey($0.url) })
        var jobs: [(Item.ID, URL, URL)] = []
        for index in items.indices {
            guard let tags = items[index].tags, items[index].info != nil else { continue }
            items[index].notes = []
            items[index].progress = 0
            items[index].output = nil
            let planned = OutputPlanner.plannedURL(for: items[index].url, sourceRoot: items[index].root, settings: settings, tags: tags)
            switch OutputPlanner.resolve(planned, input: items[index].url, policy: settings.collision, taken: taken) {
            case .write(let output):
                taken.insert(OutputPlanner.pathKey(output))
                items[index].state = .queued
                jobs.append((items[index].id, items[index].url, output))
            case .skip(let existing):
                items[index].state = .skipped("“\(existing.lastPathComponent)” already exists.")
                items[index].output = existing
            }
        }
        summary = nil
        guard !jobs.isEmpty else {
            summary = Summary(skipped: items.filter { if case .skipped = $0.state { return true }; return false }.count)
            return
        }
        isConverting = true
        cancellation = Cancellation()
        let cancellation = self.cancellation
        updateDockBadge()
        for (id, input, output) in jobs {
            queue.addOperation { [weak self] in
                guard !cancellation.isCancelled else {
                    Task { @MainActor in self?.finish(id, .failure(ConversionError.cancelled)) }
                    return
                }
                Task { @MainActor in self?.setState(id, .converting) }
                var reported = 0.0
                let result = Result {
                    try Converter.convert(input: input, to: output, settings: settings, progress: { value in
                        guard value - reported >= 0.01 || value >= 1 else { return }
                        reported = value
                        Task { @MainActor in self?.setProgress(id, value) }
                    }, isCancelled: { cancellation.isCancelled })
                }
                Task { @MainActor in self?.finish(id, result) }
            }
        }
    }

    func stop() {
        cancellation.cancel()
    }

    private func setState(_ id: Item.ID, _ state: State) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
    }

    private func setProgress(_ id: Item.ID, _ value: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .converting else { return }
        items[index].progress = value
    }

    private func finish(_ id: Item.ID, _ result: Result<ConversionOutcome, Error>) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            switch result {
            case .success(let outcome):
                items[index].state = .done
                items[index].progress = 1
                items[index].output = outcome.output
                items[index].outputBytes = outcome.bytes
                items[index].notes = outcome.notes
            case .failure(let error as ConversionError) where error == .cancelled:
                items[index].state = .ready
                items[index].progress = 0
            case .failure(let error):
                items[index].state = .failed(error.localizedDescription)
            }
        }
        updateDockBadge()
        guard !items.contains(where: \.isBusy) else { return }
        isConverting = false
        var summary = Summary(stopped: cancellation.isCancelled)
        for item in items {
            switch item.state {
            case .done:
                summary.converted += 1
                if let output = item.output { summary.outputs.append(output) }
            case .skipped: summary.skipped += 1
            case .failed: summary.failed += 1
            default: break
            }
        }
        self.summary = summary
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    private func updateDockBadge() {
        let left = items.filter(\.isBusy).count
        NSApp.dockTile.badgeLabel = left > 0 ? String(left) : nil
    }

    func revealOutputs() {
        guard let outputs = summary?.outputs, !outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
    }
}

/// Shared between the main actor and the conversion operations.
final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool { lock.withLock { flag } }
    func cancel() { lock.withLock { flag = true } }
}

extension Int64 {
    var byteText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
