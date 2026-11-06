import AppKit
import RecastCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    var body: some View {
        @Bindable var model = model
        Group {
            if model.items.isEmpty {
                DropZone(isTargeted: isTargeted) { model.chooseFiles() }
            } else {
                FileList()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            ConvertBar()
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted && !model.items.isEmpty {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle("Recast")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Button { model.chooseFiles() } label: { Label("Add Files", systemImage: "plus") }
                    .help("Add audio files or folders")
                Button { model.clear() } label: { Label("Clear List", systemImage: "trash") }
                    .help("Remove all files from the list (the files themselves are not touched)")
                    .disabled(model.items.isEmpty || model.isConverting)
            }
            ToolbarItem {
                Button { model.showInspector.toggle() } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                    .help(model.showInspector ? "Hide conversion settings" : "Show all conversion settings")
            }
        }
        .inspector(isPresented: $model.showInspector) {
            SettingsInspector()
                .inspectorColumnWidth(min: 300, ideal: 330, max: 420)
        }
    }

    private var subtitle: String {
        guard !model.items.isEmpty else { return "" }
        let files = model.items.count == 1 ? "1 file" : "\(model.items.count) files"
        if model.isReading { return "\(files) · reading…" }
        return "\(files) · \(AudioFileInfo.durationText(model.totalDuration))"
    }
}

struct DropZone: View {
    let isTargeted: Bool
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                .symbolEffect(.bounce, value: isTargeted)
            VStack(spacing: 6) {
                Text("Drop audio files or folders")
                    .font(.title2.weight(.semibold))
                Text("WAV, AIFF, FLAC, Apple Lossless, MP3, AAC, Ogg Vorbis, Opus and more.\nConvert as many as you like at once. Your originals are never changed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Choose Files…", action: choose)
                .buttonStyle(.glass)
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: isTargeted ? 3 : 1.5, dash: isTargeted ? [] : [7, 6]))
                .background(isTargeted ? Color.accentColor.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 22))
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 90)
        }
        .padding(.bottom, 70)
    }
}

struct FileList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.items) { item in
                FileRow(item: item)
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .safeAreaPadding(.bottom, 80)
    }
}

struct FileRow: View {
    @Environment(AppModel.self) private var model
    let item: AppModel.Item
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            FormatBadge(fileExtension: (item.output ?? item.url).pathExtension, readable: { if case .unreadable = item.state { return false }; return true }())
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 12)
            status
            Button { model.remove(item.id) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("Remove from the list")
            .opacity(hovering && !item.isBusy ? 1 : 0)
            .accessibilityLabel("Remove \(item.url.lastPathComponent) from the list")
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if let output = item.output, FileManager.default.fileExists(atPath: output.path) {
                Button("Show Converted File in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                Button("Play Converted File") { NSWorkspace.shared.open(output) }
            }
            Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Remove from List") { model.remove(item.id) }.disabled(item.isBusy)
        }
    }

    private var detail: String {
        guard let info = item.info else {
            if case .unreadable = item.state { return "Not an audio file macOS can read" }
            return "Reading…"
        }
        var parts = [info.summary, AudioFileInfo.durationText(info.duration)]
        if item.state == .done, let output = item.output {
            let folder = output.deletingLastPathComponent().lastPathComponent
            parts = ["→ \(output.lastPathComponent)" + (output.deletingLastPathComponent() == item.url.deletingLastPathComponent() ? "" : " in “\(folder)”")]
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .reading:
            ProgressView().controlSize(.small)
        case .ready:
            EmptyView()
        case .queued:
            Text("Waiting")
                .font(.callout)
                .foregroundStyle(.tertiary)
        case .converting:
            HStack(spacing: 8) {
                ProgressView(value: item.progress)
                    .frame(width: 110)
                Text("\(Int((item.progress * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
        case .done:
            HStack(spacing: 6) {
                if !item.notes.isEmpty {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .help(item.notes.joined(separator: "\n"))
                        .accessibilityLabel(item.notes.joined(separator: " "))
                }
                Label(item.outputBytes.byteText, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium).monospacedDigit())
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            }
        case .skipped(let reason):
            Label("Skipped", systemImage: "arrow.uturn.right.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .help(reason + " Change “If a file exists” in the settings to replace it or keep both.")
        case .unreadable(let message), .failed(let message):
            Label(item.state == .unreadable(message) ? "Can't Read" : "Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
                .help(message)
        }
    }
}

/// A small tile naming the file's format, tinted by kind (uncompressed, lossless, compressed).
struct FormatBadge: View {
    let fileExtension: String
    var readable = true

    var body: some View {
        let ext = fileExtension.uppercased()
        VStack(spacing: 1) {
            Image(systemName: readable ? "waveform" : "questionmark")
                .font(.system(size: 13, weight: .semibold))
            Text(ext.isEmpty ? "?" : String(ext.prefix(4)))
                .font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(tint)
        .frame(width: 36, height: 36)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    private var tint: Color {
        guard readable else { return .secondary }
        switch fileExtension.lowercased() {
        case "wav", "wave", "aif", "aiff", "aifc", "caf", "w64", "rf64", "bwf": return .blue
        case "flac", "alac": return .teal
        case "m4a", "mp4", "aac", "m4b": return .pink
        case "mp3", "mp2": return .orange
        case "ogg", "oga", "opus": return .purple
        default: return .gray
        }
    }
}
