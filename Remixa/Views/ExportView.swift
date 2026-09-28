import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
    @ObservedObject var document: AudioDocument
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .wav
    @State private var progress: Double = 0
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var didFinish = false

    var body: some View {
        VStack(spacing: 16) {
            Text("書き出し").font(.title2)

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
                Button("キャンセル") { dismiss() }
                    .disabled(isExporting)
                Button("書き出す") { startExport() }
                    .disabled(isExporting || document.buffer == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func startExport() {
        guard let buffer = document.buffer else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .wav ? .wav : .mpeg4Audio]
        panel.nameFieldStringValue = (document.fileURL?.deletingPathExtension().lastPathComponent ?? "Remixa") + (format == .wav ? ".wav" : ".m4a")
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        errorMessage = nil
        didFinish = false
        let settings = document.effects
        let tempo = document.tempoPercent
        let pitch = document.pitchSemitones
        let fmt = format

        Task {
            do {
                try await AudioExporter.export(
                    buffer: UncheckedSendableBox(value: buffer),
                    settings: settings,
                    tempoPercent: tempo,
                    pitchSemitones: pitch,
                    format: fmt,
                    destination: destination,
                    progress: { p in
                        Task { @MainActor in progress = p }
                    }
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
