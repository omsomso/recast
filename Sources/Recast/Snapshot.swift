import AppKit
import RecastCore
import SwiftUI

/// Development aid: `RECAST_SNAPSHOT=<folder> RECAST_FILES=<a:b:c>` adds the files, saves PNGs of the main states
/// (light and dark, default and minimum size) into the folder, converts copies into `<folder>/converted` and quits.
/// Settings are restored afterwards; originals are never touched.
enum Snapshot {
    static func runIfRequested(_ model: AppModel) {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["RECAST_SNAPSHOT"].map({ URL(fileURLWithPath: $0, isDirectory: true) }) else { return }
        let files = (environment["RECAST_FILES"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let saved = model.settings, savedInspector = model.showInspector, savedRecent = model.recentFolders
            var fresh = ConversionSettings()
            fresh.format = .mp3
            model.settings = fresh
            model.showInspector = false
            NSApp.appearance = NSAppearance(named: .aqua)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
            resize(860, 560)
            try? await Task.sleep(for: .seconds(1))
            capture(folder, "1-empty")

            model.add(files)
            try? await Task.sleep(for: .milliseconds(300))
            while model.isReading { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(500))
            capture(folder, "2-list")

            model.showInspector = true
            resize(1180, 760)
            try? await Task.sleep(for: .milliseconds(800))
            capture(folder, "3-settings-mp3")
            model.settings.format = .flac
            model.settings.flacDepth = .int16
            model.settings.sampleRate = 44100
            model.settings.volume = .loudness
            model.settings.destination = .folder
            model.settings.folderPath = folder.appendingPathComponent("converted").path
            try? await Task.sleep(for: .milliseconds(600))
            capture(folder, "4-settings-flac")
            NSApp.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .milliseconds(600))
            capture(folder, "4-settings-flac-dark")
            NSApp.appearance = NSAppearance(named: .aqua)
            model.settings.format = .aac
            model.settings.aacMode = .vbr
            model.settings.volume = .peak
            try? await Task.sleep(for: .milliseconds(600))
            capture(folder, "5-settings-aac")

            model.showInspector = false
            try? await Task.sleep(for: .milliseconds(600))
            resize(860, 560)
            try? await Task.sleep(for: .milliseconds(400))
            var convert = ConversionSettings()
            convert.format = .mp3
            convert.destination = .folder
            convert.folderPath = folder.appendingPathComponent("converted").path
            model.settings = convert
            model.convert()
            try? await Task.sleep(for: .milliseconds(150))
            capture(folder, "6-converting")
            while model.isConverting { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(500))
            capture(folder, "7-done")

            NSApp.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .milliseconds(600))
            capture(folder, "8-done-dark")
            model.showInspector = true
            resize(1180, 760)
            try? await Task.sleep(for: .milliseconds(700))
            capture(folder, "9-settings-dark")
            model.showInspector = false
            model.clear()
            try? await Task.sleep(for: .milliseconds(500))
            capture(folder, "10-empty-dark")
            NSApp.appearance = nil
            model.add(files)
            while model.isReading || model.items.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            resize(620, 420)
            try? await Task.sleep(for: .milliseconds(700))
            capture(folder, "11-minimum-size")

            model.settings = saved
            model.showInspector = savedInspector
            model.recentFolders = savedRecent
            NSApp.terminate(nil)
        }
    }

    @MainActor static func resize(_ width: CGFloat, _ height: CGFloat) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        var frame = window.frame
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: width, height: height)
        window.setFrame(frame, display: true)
    }

    @MainActor static func capture(_ folder: URL, _ name: String) {
        let url = folder.appendingPathComponent(name + ".png")
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        // The real on-screen pixels. AppKit's own rendering can't draw Liquid Glass or the list, so there is no
        // fallback: launch from a terminal that has Screen Recording permission.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 || !FileManager.default.fileExists(atPath: url.path) {
            FileHandle.standardError.write(Data("Couldn't capture \(name): screencapture needs Screen Recording permission.\n".utf8))
        }
    }
}
