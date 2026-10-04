import SwiftUI

/// Opens a clip in the v0.1 single-file editor (waveform, tempo/pitch, cut/trim/fade,
/// undo, effects, export) via an ad-hoc `AudioDocument` loaded from the clip's audio.
/// On "適用して閉じる" the edited buffer is written back into the project as the
/// clip's new source audio.
struct ClipEditorSheet: View {
    let project: RemixaProject
    let clip: Clip
    let track: Track
    @ObservedObject var timelineEngine: TimelineEngine

    @StateObject private var document = AudioDocument()
    @StateObject private var engine = AudioEngineController()
    @Environment(\.dismiss) private var dismiss
    @State private var didLoad = false
    @State private var tempoRate = 1.0
    @State private var sourceBPMText = ""
    @State private var syncToProject = false
    @State private var tempoError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("クリップを編集: \(clip.name)").font(.headline)
                Spacer()
                Button("音声編集を破棄して閉じる") { dismiss() }
                Button("音声編集を適用して閉じる") { applyAndClose() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(document.buffer == nil)
            }
            .padding()
            Divider()

            GroupBox("テンポ同期") {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("テンポ倍率")
                            Spacer()
                            Text(String(format: "%.2f×", tempoRate))
                                .monospacedDigit()
                        }
                        Slider(value: tempoRateBinding, in: 0.5...2.0, onEditingChanged: { editing in
                            if editing { project.beginUndoCoalescing() }
                            else {
                                project.endUndoCoalescing()
                                timelineEngine.refreshPlaybackSchedule()
                            }
                        })
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("元BPM")
                        HStack(spacing: 6) {
                            TextField("未設定", text: $sourceBPMText)
                                .frame(width: 82)
                                .onSubmit { saveSourceBPM() }
                            Button("設定") { saveSourceBPM() }
                                .controlSize(.small)
                        }
                        Toggle("プロジェクトBPMに同期", isOn: syncBinding)
                            .toggleStyle(.checkbox)
                    }

                    Button("プロジェクトBPMに合わせる") { synchronizeTempo() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
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
        .alert("テンポを同期できません", isPresented: Binding(
            get: { tempoError != nil },
            set: { if !$0 { tempoError = nil } }
        )) {
            Button("閉じる", role: .cancel) { tempoError = nil }
        } message: {
            Text(tempoError ?? "")
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            tempoRate = clip.tempoRate
            sourceBPMText = clip.sourceBPM.map { String(format: "%.1f", $0) } ?? ""
            syncToProject = clip.syncToProject
            engine.attach(document: document)
            let url = clip.resolvedURL(packageAudioDir: project.fileURL?.appendingPathComponent("Audio"))
            document.load(url: url)
        }
        .onChange(of: document.effects) { _, _ in engine.syncEffects() }
        .onChange(of: document.tempoPercent) { _, _ in engine.syncEffects() }
        .onChange(of: document.pitchSemitones) { _, _ in engine.syncEffects() }
    }

    private var currentClip: Clip {
        track.clips.first(where: { $0.id == clip.id }) ?? clip
    }

    private var tempoRateBinding: Binding<Double> {
        Binding(
            get: { tempoRate },
            set: { rate in
                tempoRate = rate
                project.updateClip(clip, on: track, tempoRate: rate)
                syncToProject = currentClip.syncToProject
            }
        )
    }

    private var syncBinding: Binding<Bool> {
        Binding(
            get: { syncToProject },
            set: { enabled in
                if enabled {
                    synchronizeTempo()
                } else {
                    project.updateClip(clip, on: track, syncToProject: false)
                    syncToProject = false
                }
            }
        )
    }

    private func synchronizeTempo() {
        do {
            let rawBPM = sourceBPMText.trimmingCharacters(in: .whitespacesAndNewlines)
            let overrideBPM: Double?
            if rawBPM.isEmpty {
                overrideBPM = nil
            } else if let value = Double(rawBPM), value.isFinite, value > 0 {
                overrideBPM = value
            } else {
                throw NSError(domain: "Remixa", code: 53, userInfo: [NSLocalizedDescriptionKey: "元BPMは0より大きい数値で入力してください"])
            }
            try project.syncClipTempo(clipId: clip.id, sourceBPM: overrideBPM)
            updateTempoFieldsFromProject()
            tempoError = nil
            timelineEngine.refreshPlaybackSchedule()
        } catch {
            tempoError = error.localizedDescription
        }
    }

    private func saveSourceBPM() {
        let rawBPM = sourceBPMText.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawBPM.isEmpty {
            project.updateClip(clip, on: track, sourceBPM: .some(nil))
        } else if let sourceBPM = Double(rawBPM), sourceBPM.isFinite, sourceBPM > 0 {
            project.updateClip(clip, on: track, sourceBPM: .some(.some(sourceBPM)))
        } else {
            tempoError = "元BPMは0より大きい数値で入力してください"
            return
        }
        updateTempoFieldsFromProject()
        timelineEngine.refreshPlaybackSchedule()
    }

    private func updateTempoFieldsFromProject() {
        let updated = currentClip
        tempoRate = updated.tempoRate
        sourceBPMText = updated.sourceBPM.map { String(format: "%.1f", $0) } ?? ""
        syncToProject = updated.syncToProject
    }

    private func applyAndClose() {
        guard let buffer = document.buffer else { dismiss(); return }
        let cacheKey = "clip-edit-\(UUID().uuidString)"
        project.replaceClipAudio(clip, on: track, newBuffer: buffer, cacheKey: cacheKey)
        dismiss()
    }
}
