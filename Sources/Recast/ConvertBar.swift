import AppKit
import RecastCore
import SwiftUI

/// The floating glass bar: format, quality, destination and the Convert button.
struct ConvertBar: View {
    @Environment(AppModel.self) private var model
    @State private var naming = false
    @State private var presetName = ""

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 10) {
                formatMenu
                qualityMenu
                destinationMenu
                Spacer(minLength: 6)
                summary
                convertButton
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
        }
        .alert("Save Preset", isPresented: $naming) {
            TextField("Name", text: $presetName)
            Button("Save") { model.savePreset(named: presetName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the format, quality, audio, volume and tag settings. Where files go isn't part of a preset.")
        }
    }

    private var formatMenu: some View {
        Menu {
            Section("Lossless") {
                ForEach(OutputFormat.lossless) { format in formatButton(format) }
            }
            Section("Compressed") {
                ForEach(OutputFormat.compressed) { format in formatButton(format) }
            }
            Divider()
            Menu("Presets") {
                ForEach(Preset.builtIn) { preset in presetButton(preset) }
                if !model.userPresets.isEmpty {
                    Divider()
                    ForEach(model.userPresets) { preset in presetButton(preset) }
                }
                Divider()
                Button("Save Current Settings as Preset…") {
                    presetName = ""
                    naming = true
                }
                if !model.userPresets.isEmpty {
                    Menu("Delete Preset") {
                        ForEach(model.userPresets) { preset in
                            Button(preset.name) { model.deletePreset(preset) }
                        }
                    }
                }
            }
        } label: {
            Label(model.settings.format.title, systemImage: model.settings.format.isLossless ? "waveform" : "waveform.path")
                .fontWeight(.semibold)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .help("Output format")
        .disabled(model.isConverting)
    }

    private func formatButton(_ format: OutputFormat) -> some View {
        Button {
            model.settings.format = format
        } label: {
            if model.settings.format == format { Image(systemName: "checkmark") }
            Text(format.title)
            Text(format.summary)
        }
    }

    private func presetButton(_ preset: Preset) -> some View {
        Button {
            model.apply(preset)
        } label: {
            if model.isCurrent(preset) { Image(systemName: "checkmark") }
            Text(preset.name)
        }
    }

    private var qualityMenu: some View {
        let settings = model.settings
        return Menu {
            ForEach(settings.format.qualityChoices) { choice in
                Button {
                    model.settings = choice.applied(to: model.settings)
                } label: {
                    if choice.isSelected(in: settings) { Image(systemName: "checkmark") }
                    Text(choice.title)
                    if !choice.detail.isEmpty { Text(choice.detail) }
                }
            }
            Divider()
            Button("Custom…") { model.showInspector = true }
        } label: {
            Text(qualityTitle)
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .help(settings.processingSummary.isEmpty ? "Quality" : "Quality · also: " + settings.processingSummary.joined(separator: ", "))
        .disabled(model.isConverting)
    }

    private var qualityTitle: String {
        let extras = model.settings.processingSummary
        return ([model.settings.qualitySummary] + extras.prefix(2)).joined(separator: " · ")
    }

    private var destinationMenu: some View {
        Menu {
            Button {
                model.settings.destination = .nextToOriginal
            } label: {
                if model.settings.destination == .nextToOriginal { Image(systemName: "checkmark") }
                Text("Next to Originals")
            }
            if !model.recentFolders.isEmpty {
                Section("Folders") {
                    ForEach(model.recentFolders, id: \.self) { path in
                        Button {
                            model.useFolder(path)
                        } label: {
                            if model.settings.destination == .folder && model.settings.folderPath == path { Image(systemName: "checkmark") }
                            Text(FileManager.default.displayName(atPath: path))
                            Text((path as NSString).abbreviatingWithTildeInPath)
                        }
                    }
                }
            }
            Button("Choose Folder…") { model.chooseFolder() }
            Divider()
            Toggle("Keep Folder Structure", isOn: Binding(get: { model.settings.keepFolderStructure },
                                                          set: { model.settings.keepFolderStructure = $0 }))
                .disabled(model.settings.destination != .folder)
            Picker("If a File Exists", selection: Binding(get: { model.settings.collision }, set: { model.settings.collision = $0 })) {
                ForEach(CollisionPolicy.allCases) { Text($0.title).tag($0) }
            }
            if model.settings.destination == .folder, let path = model.settings.folderPath {
                Divider()
                Button("Show Folder in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            }
        } label: {
            Label(model.destinationTitle, systemImage: model.settings.destination == .folder ? "folder" : "arrow.turn.down.right")
                .lineLimit(1)
                .frame(maxWidth: 170)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .help(model.settings.destination == .folder ? (model.settings.folderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "")
              : "Converted files are saved next to each original")
        .disabled(model.isConverting)
    }

    @ViewBuilder private var summary: some View {
        if let summary = model.summary, !model.isConverting {
            HStack(spacing: 8) {
                Text(summaryText(summary))
                    .font(.callout)
                    .foregroundStyle(summary.failed > 0 ? .orange : .secondary)
                    .lineLimit(1)
                    .fixedSize()
                if !summary.outputs.isEmpty {
                    Button("Show") { model.revealOutputs() }
                        .buttonStyle(.link)
                        .help("Show the converted files in the Finder")
                }
            }
        } else if model.isConverting {
            let left = model.items.filter(\.isBusy).count
            Text(left == 1 ? "1 file left" : "\(left) files left")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private func summaryText(_ summary: AppModel.Summary) -> String {
        var parts: [String] = []
        if summary.converted > 0 || (summary.skipped == 0 && summary.failed == 0) { parts.append("Converted \(summary.converted)") }
        if summary.skipped > 0 { parts.append("\(summary.skipped) skipped") }
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        if summary.stopped { parts.append("stopped") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var convertButton: some View {
        if model.isConverting {
            Button(action: model.stop) {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .keyboardShortcut(".", modifiers: .command)
        } else {
            Button(action: model.convert) {
                Label(convertTitle, systemImage: "arrow.triangle.2.circlepath")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.convertibleCount == 0 || model.isReading)
        }
    }

    private var convertTitle: String {
        let count = model.convertibleCount
        return count <= 1 ? "Convert" : "Convert \(count) Files"
    }
}
