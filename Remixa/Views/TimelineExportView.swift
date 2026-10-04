import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

/// Exports the full multitrack mix (v0.2), mirroring `ExportView` (v0.1 single clip).
struct TimelineExportView: View {
    @ObservedObject var project: RemixaProject
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .wav
    @State private var progress: Double = 0
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var didFinish = false

    var body: some View {
        VStack(spacing: 16) {
            Text("ミックスを書き出し").font(.title2)
            Text("全トラック・全クリップを1つのファイルにまとめて書き出します。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("形式", selection: $format) {
                Text("WAV").tag(ExportFormat.wav)
                Text("M4A").tag(ExportFormat.m4a)
            }
            .pickerStyle(.segmented)

            if isExporting {
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%")
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            if didFinish {
                Text("書き出しが完了しました").foregroundStyle(.green)
            }

            HStack {
                Button("キャンセル") { dismiss() }.disabled(isExporting)
                Button("書き出す") { startExport() }
                    .disabled(isExporting || project.projectDuration <= 0)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func startExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .wav ? .wav : .mpeg4Audio]
        panel.nameFieldStringValue = (project.fileURL?.deletingPathExtension().lastPathComponent ?? "Remixa Mix") + (format == .wav ? ".wav" : ".m4a")
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        var infos: [TimelineExporter.TrackExportInfo] = []
        let anySolo = project.anySolo
        for track in project.tracks {
            let audible = track.solo || (!anySolo && !track.mute)
            let clips = track.clips.map {
                TimelineExporter.TrackExportInfo.SourceClip(clip: $0, sourceURL: project.sourceURL(for: $0))
            }
            infos.append(TimelineExporter.TrackExportInfo(
                clips: clips, volume: track.volume, pan: track.pan,
                audible: audible, effects: track.effects
            ))
        }
        let masterVolume = project.masterVolume
        let duration = project.projectDuration
        let fmt = format

        isExporting = true
        errorMessage = nil
        didFinish = false

        Task {
            do {
                try await TimelineExporter.export(
                    tracks: infos, masterVolume: masterVolume, totalDuration: duration,
                    format: fmt, destination: destination,
                    progress: { p in Task { @MainActor in progress = p } }
                )
                await MainActor.run {
                    isExporting = false
                    didFinish = true
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    errorMessage = "書き出しに失敗しました: \(error.localizedDescription)"
                }
            }
        }
    }
}
