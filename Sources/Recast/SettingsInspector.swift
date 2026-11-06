import AppKit
import RecastCore
import SwiftUI

/// Every setting, grouped. The bar covers the common choices; this is for the rest.
struct SettingsInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent("Preset") { PresetMenu() }
            }
            formatSection($model.settings)
            audioSection($model.settings)
            volumeSection($model.settings)
            Section("Tags") {
                Toggle("Copy tags", isOn: $model.settings.copyTags)
                Toggle("Copy cover art", isOn: $model.settings.copyArtwork)
                    .disabled(!model.settings.copyTags)
                Toggle("Keep original file dates", isOn: $model.settings.keepFileDates)
            }
            outputSection($model.settings)
        }
        .formStyle(.grouped)
        .disabled(model.isConverting)
    }

    // MARK: Format

    @ViewBuilder
    private func formatSection(_ settings: Binding<ConversionSettings>) -> some View {
        let value = settings.wrappedValue
        Section {
            Picker("Format", selection: settings.format) {
                Section("Lossless") { ForEach(OutputFormat.lossless) { Text($0.title).tag($0) } }
                Section("Compressed") { ForEach(OutputFormat.compressed) { Text($0.title).tag($0) } }
            }
            switch value.format {
            case .wav, .aiff, .caf, .flac, .alac:
                Picker("Bit depth", selection: Binding(get: { value.selectedDepth }, set: { settings.wrappedValue.setDepth($0) })) {
                    ForEach(value.format.bitDepths) { Text($0.title).tag($0) }
                }
                if value.format == .flac {
                    Toggle("Faster encoding", isOn: settings.flacFast)
                }
            case .mp3:
                Picker("Mode", selection: settings.mp3Mode) { ForEach(MP3Mode.allCases) { Text($0.title).tag($0) } }
                if value.mp3Mode == .vbr {
                    Picker("Quality", selection: settings.mp3VBRQuality) {
                        ForEach(0...9, id: \.self) { level in
                            Text(level == 0 ? "V0 (best, about 245 kbps)" : level == 2 ? "V2 (about 190 kbps)" : level == 4 ? "V4 (about 165 kbps)" : "V\(level)").tag(level)
                        }
                    }
                } else {
                    bitRatePicker(settings.mp3Bitrate, [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320])
                }
                Toggle("Joint stereo", isOn: settings.mp3JointStereo)
                    .help("Saves bits on what both channels share. Turn off only for material with very different channels.")
            case .aac:
                Picker("Profile", selection: settings.aacProfile) { ForEach(AACProfile.allCases) { Text($0.title).tag($0) } }
                Picker("Mode", selection: settings.aacMode) { ForEach(AACMode.allCases) { Text($0.title).tag($0) } }
                if value.aacMode == .vbr {
                    LabeledContent("Quality") {
                        Slider(value: Binding(get: { Double(value.aacVBRQuality) }, set: { settings.wrappedValue.aacVBRQuality = Int($0.rounded()) }),
                               in: 0...127, step: 1) {
                            EmptyView()
                        } minimumValueLabel: { Text("Smaller").font(.caption) } maximumValueLabel: { Text("Better").font(.caption) }
                    }
                } else {
                    bitRatePicker(settings.aacBitrate, value.aacProfile == .he ? [24, 32, 40, 48, 56, 64, 80]
                                                                               : [64, 80, 96, 112, 128, 160, 192, 224, 256, 288, 320])
                }
            case .vorbis:
                Picker("Mode", selection: settings.vorbisMode) { ForEach(VorbisMode.allCases) { Text($0.title).tag($0) } }
                if value.vorbisMode == .quality {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: settings.vorbisQuality, in: -1...10, step: 1)
                            Text(String(Int(value.vorbisQuality)))
                                .monospacedDigit()
                                .frame(width: 22, alignment: .trailing)
                        }
                    }
                } else {
                    bitRatePicker(settings.vorbisBitrate, [64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 500])
                }
            case .opus:
                bitRatePicker(settings.opusBitrate, [24, 32, 48, 64, 96, 128, 160, 192, 256, 320, 384, 510])
            }
        } header: {
            Text("Format")
        } footer: {
            Text(formatFooter(value))
        }
    }

    private func formatFooter(_ settings: ConversionSettings) -> String {
        switch settings.format {
        case .wav, .aiff, .caf, .alac:
            return settings.format.summary + " “Same as source” keeps each file's bit depth; compressed sources become 24-bit."
        case .flac:
            return settings.format.summary + " FLAC stores up to 24 bits."
        case .mp3:
            return "LAME 3.100. Variable bit rate gives the best quality for the size; constant bit rate suits old players."
        case .aac:
            return "Apple's AAC encoder, saved as .m4a. Constrained variable is what Apple Music uses. HE-AAC is for low bit rates."
        case .vorbis:
            return "libvorbis 1.3.7. Quality 6 is about 192 kbps."
        case .opus:
            return "Apple's Opus encoder in an Ogg file. Opus always plays at 48 kHz, so other rates are resampled."
        }
    }

    private func bitRatePicker(_ binding: Binding<Int>, _ rates: [Int]) -> some View {
        Picker("Bit rate", selection: binding) {
            ForEach(rates.contains(binding.wrappedValue) ? rates : (rates + [binding.wrappedValue]).sorted(), id: \.self) { rate in
                Text("\(rate) kbps").tag(rate)
            }
        }
    }

    // MARK: Audio

    @ViewBuilder
    private func audioSection(_ settings: Binding<ConversionSettings>) -> some View {
        let value = settings.wrappedValue
        let allRates: [Double] = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000]
        let rates = value.format.sampleRates.map { allowed in allRates.filter(allowed.contains) } ?? allRates
        Section {
            Picker("Sample rate", selection: settings.sampleRate) {
                Text("Same as source").tag(Double?.none)
                Divider()
                ForEach(rates, id: \.self) { rate in Text(ConversionSettings.rateText(rate)).tag(Double?.some(rate)) }
            }
            .onChange(of: value.format) { _, format in
                if let rate = settings.wrappedValue.sampleRate, let allowed = format.sampleRates, !allowed.contains(rate) {
                    settings.wrappedValue.sampleRate = nil
                }
            }
            Picker("Channels", selection: settings.channels) {
                ForEach(ChannelMode.allCases) { Text($0.title).tag($0) }
            }
            if usesIntegerSamples(value) {
                Toggle("Dither", isOn: settings.dither)
                Toggle("Noise shaping", isOn: settings.noiseShaping)
                    .disabled(!value.dither)
            }
        } header: {
            Text("Audio")
        } footer: {
            if usesIntegerSamples(value) {
                Text("Dither adds a trace of noise when samples are rounded to fewer bits, so quiet passages fade out smoothly. It's skipped when nothing changes. Noise shaping moves that noise to where it's hardest to hear (44.1 and 48 kHz).")
            } else {
                Text("Sample rate conversion uses Apple's mastering-quality converter. Stereo to mono averages the channels; surround is mixed down with the standard ITU levels.")
            }
        }
    }

    private func usesIntegerSamples(_ settings: ConversionSettings) -> Bool {
        settings.format.isLossless && settings.selectedDepth != .float32 && settings.selectedDepth != .int32
    }

    // MARK: Volume

    @ViewBuilder
    private func volumeSection(_ settings: Binding<ConversionSettings>) -> some View {
        let value = settings.wrappedValue
        Section {
            Picker("Volume", selection: settings.volume) {
                ForEach(VolumeMode.allCases) { Text($0.title).tag($0) }
            }
            switch value.volume {
            case .none:
                EmptyView()
            case .loudness:
                LabeledContent("Target") {
                    HStack(spacing: 6) {
                        NumberField(value: settings.loudnessTarget, range: -40...0, step: 1, unit: "LUFS")
                        Menu {
                            ForEach([(-14.0, "Spotify, YouTube, Tidal"), (-16, "Apple Music, podcasts"), (-23, "EBU R128 broadcast"), (-24, "US broadcast")], id: \.0) { target, use in
                                Button {
                                    settings.wrappedValue.loudnessTarget = target
                                } label: {
                                    Text("\(Int(target)) LUFS")
                                    Text(use)
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Common targets")
                    }
                }
                LabeledContent("Peak limit") {
                    NumberField(value: settings.truePeakCeiling, range: -6...0, step: 0.5, unit: "dBTP")
                }
            case .peak:
                LabeledContent("Peaks at") {
                    NumberField(value: settings.peakTarget, range: -20...0, step: 0.5, unit: "dB")
                }
            case .gain:
                LabeledContent("Change by") {
                    NumberField(value: settings.gainDB, range: -40...40, step: 0.5, unit: "dB")
                }
            }
        } header: {
            Text("Volume")
        } footer: {
            switch value.volume {
            case .none: Text("Files keep their level.")
            case .loudness: Text("Measures each file's loudness (EBU R128) and sets it to the target, without letting the peaks pass the limit. Nothing is compressed or limited: a file that can't get louder without going over stays a little quieter.")
            case .peak: Text("Raises or lowers each file so its loudest sample sits at this level.")
            case .gain: Text("The same change for every file. Samples pushed past full scale are clipped.")
            }
        }
    }

    // MARK: Output

    @ViewBuilder
    private func outputSection(_ settings: Binding<ConversionSettings>) -> some View {
        let value = settings.wrappedValue
        Section {
            Picker("Save to", selection: Binding(get: { value.destination }, set: { destination in
                if destination == .folder, value.folderPath == nil { model.chooseFolder() } else { settings.wrappedValue.destination = destination }
            })) {
                Text("Next to originals").tag(Destination.nextToOriginal)
                Text("A folder").tag(Destination.folder)
            }
            if value.destination == .folder {
                LabeledContent("Folder") {
                    HStack(spacing: 6) {
                        Text(value.folderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { model.chooseFolder() }
                    }
                }
                Toggle("Keep folder structure", isOn: settings.keepFolderStructure)
                    .help("Dropped folders are recreated inside the destination folder.")
            }
            Picker("If a file exists", selection: settings.collision) {
                ForEach(CollisionPolicy.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("File name") {
                HStack(spacing: 6) {
                    TextField("File name", text: settings.namePattern, prompt: Text("{name}"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                    Menu {
                        ForEach(OutputPlanner.tokens, id: \.token) { token in
                            Button(token.title) { settings.wrappedValue.namePattern += (value.namePattern.isEmpty || value.namePattern.hasSuffix(" ") ? "" : " ") + token.token }
                        }
                        Divider()
                        Button("Reset to Original Name") { settings.wrappedValue.namePattern = "{name}" }
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Insert a tag into the name")
                }
            }
        } header: {
            Text("Output")
        } footer: {
            Text(outputFooter(value))
        }
    }

    private func outputFooter(_ settings: ConversionSettings) -> String {
        var example = AudioTags()
        example.title = "Song"
        example.artist = "Artist"
        example.album = "Album"
        example.track = 1
        example.date = "2024"
        let name = OutputPlanner.fileName(pattern: settings.namePattern, input: URL(fileURLWithPath: "/Original Name.wav"),
                                          tags: example, format: settings.format)
        return "Example: “\(name).\(settings.format.fileExtension)”. Originals are never replaced; a file of the same name gets a number instead."
    }
}

/// A number with a stepper and a unit, e.g. "-14 LUFS".
struct NumberField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, $0)) }),
                      format: .number.precision(.fractionLength(0...1)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
            Text(unit)
                .foregroundStyle(.secondary)
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
        }
    }
}

struct PresetMenu: View {
    @Environment(AppModel.self) private var model
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        Menu {
            ForEach(Preset.builtIn) { preset in item(preset) }
            if !model.userPresets.isEmpty {
                Divider()
                ForEach(model.userPresets) { preset in item(preset) }
            }
            Divider()
            Button("Save Current Settings as Preset…") { name = ""; naming = true }
            if !model.userPresets.isEmpty {
                Menu("Delete Preset") {
                    ForEach(model.userPresets) { preset in Button(preset.name) { model.deletePreset(preset) } }
                }
            }
        } label: {
            Text(currentName)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Apply or save a set of settings")
        .alert("Save Preset", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") { model.savePreset(named: name) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the format, quality, audio, volume and tag settings. Where files go isn't part of a preset.")
        }
    }

    private var currentName: String {
        (Preset.builtIn + model.userPresets).first(where: model.isCurrent)?.name ?? "Custom"
    }

    private func item(_ preset: Preset) -> some View {
        Button {
            model.apply(preset)
        } label: {
            if model.isCurrent(preset) { Image(systemName: "checkmark") }
            Text(preset.name)
        }
    }
}
