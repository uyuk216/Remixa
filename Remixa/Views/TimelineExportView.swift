import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

@MainActor
private final class TimelineExportProgress: ObservableObject {
    @Published var value = 0.0
}

/// Offline export controls for the multitrack arrangement.
struct TimelineExportView: View {
    @ObservedObject var project: RemixaProject
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .wav
    @State private var wavEncoding: TimelineExporter.WAVEncoding = .pcm24
    @State private var m4aQuality: TimelineExporter.M4AQuality = .kbps256
    @State private var exportMode: ExportMode = .mix
    @StateObject private var exportProgress = TimelineExportProgress()
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var didFinish = false

    private enum ExportMode: String, CaseIterable, Identifiable, Sendable {
        case mix
        case stems

        var id: Self { self }
        var title: String {
            switch self {
            case .mix: "ミックス"
            case .stems: "トラック別"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("書き出し").font(.title2).frame(maxWidth: .infinity)

            Picker("書き出し対象", selection: $exportMode) {
                ForEach(ExportMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(exportMode == .mix
                 ? "全トラックを1つのファイルにまとめて書き出します。"
                 : "トラックごとに個別のファイルを書き出します。保存先フォルダを選択してください。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("形式", selection: $format) {
                Text("WAV").tag(ExportFormat.wav)
                Text("M4A").tag(ExportFormat.m4a)
            }
            .pickerStyle(.segmented)

            if format == .wav {
                Picker("WAV品質", selection: $wavEncoding) {
                    ForEach(TimelineExporter.WAVEncoding.allCases) { encoding in
                        Text(encoding.title).tag(encoding)
                    }
                }
                .pickerStyle(.menu)
            } else {
                Picker("M4A品質", selection: $m4aQuality) {
                    ForEach(TimelineExporter.M4AQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .pickerStyle(.menu)
            }

            Divider()

            Toggle("書き出しにメトロノームを含める", isOn: Binding(
                get: { project.exportMetronomeEnabled },
                set: { project.setMetronomeSettings(exportEnabled: $0) }
            ))
            HStack(spacing: 10) {
                Text("音量")
                Slider(value: Binding(
                    get: { project.metronomeVolume },
                    set: { project.setMetronomeSettings(volume: $0) }
                ), in: 0...1, onEditingChanged: { editing in
                    if editing { project.beginUndoCoalescing() } else { project.endUndoCoalescing() }
                })
                .disabled(!project.exportMetronomeEnabled)
                Text("\(Int(project.metronomeVolume * 100))%")
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            if exportMode == .stems, project.exportMetronomeEnabled, project.metronomeVolume > 0 {
                Text("メトロノームは別のステムとして書き出します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isExporting {
                ProgressView(value: exportProgress.value)
                Text("\(Int(exportProgress.value * 100))%")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .font(.caption.monospacedDigit())
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            }
            if didFinish {
                Text("書き出しが完了しました").foregroundStyle(.green)
            }

            HStack {
                Button("キャンセル") { dismiss() }.disabled(isExporting)
                Spacer()
                Button("書き出す") { startExport() }
                    .disabled(isExporting || project.projectDuration <= 0)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func startExport() {
        let destination: URL
        if exportMode == .mix {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format == .wav ? .wav : .mpeg4Audio]
            let baseName = project.fileURL?.deletingPathExtension().lastPathComponent ?? "Remixa Mix"
            panel.nameFieldStringValue = baseName + (format == .wav ? ".wav" : ".m4a")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "保存先を選択"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }

        var infos: [TimelineExporter.TrackExportInfo] = []
        let anySolo = project.anySolo
        for track in project.tracks {
            let audible = track.solo || (!anySolo && !track.mute)
            let clips = track.clips.map {
                TimelineExporter.TrackExportInfo.SourceClip(clip: $0, sourceURL: project.sourceURL(for: $0))
            }
            infos.append(TimelineExporter.TrackExportInfo(
                name: track.name, clips: clips, volume: track.volume, pan: track.pan,
                audible: audible, effects: track.effects
            ))
        }

        let masterVolume = project.masterVolume
        let duration = project.projectDuration
        let fmt = format
        let mode = exportMode
        let options = TimelineExporter.ExportOptions(
            wavEncoding: wavEncoding,
            m4aQuality: m4aQuality,
            metronomeEnabled: project.exportMetronomeEnabled,
            metronomeVolume: project.metronomeVolume,
            bpm: project.bpm,
            beatsPerBar: project.beatsPerBar
        )

        isExporting = true
        exportProgress.value = 0
        errorMessage = nil
        didFinish = false

        let progressModel = exportProgress
        Task { @MainActor in
            do {
                switch mode {
                case .mix:
                    try await TimelineExporter.export(
                        tracks: infos, masterVolume: masterVolume, totalDuration: duration,
                        format: fmt, destination: destination, options: options,
                        progress: { p in Task { @MainActor in progressModel.value = p } }
                    )
                case .stems:
                    try await TimelineExporter.exportStems(
                        tracks: infos, totalDuration: duration, format: fmt,
                        directory: destination, options: options,
                        progress: { p in Task { @MainActor in progressModel.value = p } }
                    )
                }
                isExporting = false
                didFinish = true
            } catch {
                isExporting = false
                errorMessage = "書き出しに失敗しました: \(error.localizedDescription)"
            }
        }
    }
}
