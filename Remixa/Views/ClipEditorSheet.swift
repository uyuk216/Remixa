import SwiftUI

/// Opens a clip in the v0.1 single-file editor (waveform, tempo/pitch, cut/trim/fade,
/// undo, effects, export) via an ad-hoc `AudioDocument` loaded from the clip's audio.
/// On "適用して閉じる" the edited buffer is written back into the project as the
/// clip's new source audio.
struct ClipEditorSheet: View {
    let project: RemixaProject
    let clip: Clip
    let track: Track

    @StateObject private var document = AudioDocument()
    @StateObject private var engine = AudioEngineController()
    @Environment(\.dismiss) private var dismiss
    @State private var didLoad = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("クリップを編集: \(clip.name)").font(.headline)
                Spacer()
                Button("閉じる（破棄）") { dismiss() }
                Button("適用して閉じる") { applyAndClose() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(document.buffer == nil)
            }
            .padding()
            Divider()

            if document.isLoading || document.buffer == nil {
                ProgressView("読み込み中…").padding()
                Spacer()
            } else {
                WaveformView(engine: engine)
                    .frame(minHeight: 200)
                    .padding()
                TransportView(engine: engine)
                    .padding(.horizontal)
                Divider().padding(.vertical, 8)
                EffectsRackView(effects: $document.effects)
                    .padding(.horizontal)
            }
        }
        .frame(width: 760, height: 640)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            engine.attach(document: document)
            let url = clip.resolvedURL(packageAudioDir: project.fileURL?.appendingPathComponent("Audio"))
            document.load(url: url)
        }
        .onChange(of: document.effects) { _, _ in engine.syncEffects() }
        .onChange(of: document.tempoPercent) { _, _ in engine.syncEffects() }
        .onChange(of: document.pitchSemitones) { _, _ in engine.syncEffects() }
    }

    private func applyAndClose() {
        guard let buffer = document.buffer else { dismiss(); return }
        let cacheKey = "clip-edit-\(UUID().uuidString)"
        project.replaceClipAudio(clip, on: track, newBuffer: buffer, cacheKey: cacheKey)
        dismiss()
    }
}
