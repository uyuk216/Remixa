import SwiftUI
import AVFoundation

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
                if let error = document.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding()
                } else {
                    ProgressView("読み込み中…").padding()
                }
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
            loadTrimmedClipAudio(from: url)
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

    private func loadTrimmedClipAudio(from url: URL) {
        document.isLoading = true
        document.errorMessage = nil
        let sourceStart = clip.sourceStart
        let duration = clip.duration
        Task { @MainActor in
            do {
                let trimmedURL = try await Task.detached(priority: .userInitiated) {
                    try ClipEditorAudioRegionLoader.writeRegionCopy(
                        from: url,
                        sourceStart: sourceStart,
                        duration: duration
                    )
                }.value
                document.load(url: trimmedURL)
            } catch {
                document.isLoading = false
                document.errorMessage = "読み込みに失敗しました: \(error.localizedDescription)"
            }
        }
    }

    private func applyAndClose() {
        guard let buffer = document.buffer else { dismiss(); return }
        let cacheKey = "clip-edit-\(UUID().uuidString)"
        project.replaceClipAudio(clip, on: track, newBuffer: buffer, cacheKey: cacheKey)
        dismiss()
    }
}

/// The editor works on the audio that is audible in the clip. Staging that region
/// in a temporary file lets `AudioDocument` keep its normal URL-based loading flow.
private enum ClipEditorAudioRegionLoader {
    static func writeRegionCopy(from sourceURL: URL, sourceStart: Double, duration: Double) throws -> URL {
        let buffer = try AudioFileRegionReader.read(url: sourceURL, sourceStart: sourceStart, duration: duration)
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remixa-clip-editor-\(UUID().uuidString).caf")
        let audioFile = try AVAudioFile(
            forWriting: destinationURL,
            settings: buffer.format.settings,
            commonFormat: buffer.format.commonFormat,
            interleaved: buffer.format.isInterleaved
        )
        try audioFile.write(from: buffer)
        return destinationURL
    }
}

/// Compact, non-modal controls for the selected multitrack clip.
struct ClipInspectorView: View {
    @ObservedObject var project: RemixaProject
    @ObservedObject var track: Track
    let clip: Clip
    @ObservedObject var timelineEngine: TimelineEngine

    @State private var draftName = ""
    @State private var sourceBPMText = ""
    @State private var errorMessage: String?

    private var currentClip: Clip {
        track.clips.first(where: { $0.id == clip.id }) ?? clip
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("インスペクタ").font(.headline)
                    Text(track.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .remixaToggleInspector, object: nil)
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.plain)
                .help("インスペクタを閉じる (⌘⌥I)")
            }
            .padding(12)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    inspectorSection("クリップ") {
                        TextField("クリップ名", text: $draftName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { saveName() }
                        HStack {
                            Text("位置")
                            Spacer()
                            TextField("秒", value: positionBinding, format: .number.precision(.fractionLength(2)))
                                .frame(width: 88)
                                .multilineTextAlignment(.trailing)
                                .onSubmit { timelineEngine.refreshPlaybackSchedule() }
                            Text("秒").foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("長さ")
                            Spacer()
                            TextField("秒", value: durationBinding, format: .number.precision(.fractionLength(2)))
                                .frame(width: 88)
                                .multilineTextAlignment(.trailing)
                                .onSubmit { timelineEngine.refreshPlaybackSchedule() }
                            Text("秒").foregroundStyle(.secondary)
                        }
                    }

                    inspectorSection("音量とフェード") {
                        valueSlider(title: "ゲイン", value: gainBinding, range: 0...2, valueText: String(format: "%.2f×", currentClip.gain))
                        valueSlider(title: "フェードイン", value: fadeInBinding, range: 0...fadeLimit, valueText: String(format: "%.2f 秒", currentClip.fadeIn))
                        valueSlider(title: "フェードアウト", value: fadeOutBinding, range: 0...fadeLimit, valueText: String(format: "%.2f 秒", currentClip.fadeOut))
                    }

                    inspectorSection("テンポ") {
                        valueSlider(
                            title: "倍率",
                            value: tempoRateBinding,
                            range: 0.5...2,
                            valueText: String(format: "%.2f×", currentClip.tempoRate),
                            disabled: currentClip.syncToProject
                        )
                        HStack(spacing: 6) {
                            Text("元BPM")
                            TextField("未設定", text: $sourceBPMText)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { saveSourceBPM() }
                            Button("設定") { saveSourceBPM() }
                                .controlSize(.small)
                        }
                        Toggle("プロジェクトBPMに同期", isOn: syncBinding)
                            .toggleStyle(.checkbox)
                        Button("プロジェクトBPMに合わせる") { synchronizeTempo() }
                    }

                    inspectorSection("ピッチとキー") {
                        Stepper(value: pitchBinding, in: -12...12) {
                            Text("ピッチ  \(currentClip.pitchSemitones > 0 ? "+" : "")\(currentClip.pitchSemitones) 半音")
                                .monospacedDigit()
                        }
                        HStack {
                            Text("検出キー")
                            Spacer()
                            Text(currentClip.detectedKey?.displayName ?? "未検出")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        HStack {
                            Button("キーを検出") { detectKey() }
                            Button("プロジェクトキーに合わせる") { matchKey() }
                                .disabled(project.projectKey == nil || currentClip.detectedKey == nil)
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { refreshDrafts() }
        .onChange(of: clip.id) { _, _ in refreshDrafts() }
        .onChange(of: currentClip.sourceBPM) { _, value in
            sourceBPMText = value.map { String(format: "%.1f", $0) } ?? ""
        }
    }

    private var fadeLimit: Double { max(0.02, currentClip.timelineDuration) }

    private var positionBinding: Binding<Double> {
        Binding(
            get: { currentClip.timelineStart },
            set: { project.updateClip(currentClip, on: track, timelineStart: $0) }
        )
    }

    private var durationBinding: Binding<Double> {
        Binding(
            get: { currentClip.timelineDuration },
            set: { project.updateClip(currentClip, on: track, duration: $0) }
        )
    }

    private var gainBinding: Binding<Double> {
        Binding(get: { currentClip.gain }, set: { project.updateClip(currentClip, on: track, gain: $0) })
    }

    private var fadeInBinding: Binding<Double> {
        Binding(get: { currentClip.fadeIn }, set: { project.updateClip(currentClip, on: track, fadeIn: $0) })
    }

    private var fadeOutBinding: Binding<Double> {
        Binding(get: { currentClip.fadeOut }, set: { project.updateClip(currentClip, on: track, fadeOut: $0) })
    }

    private var tempoRateBinding: Binding<Double> {
        Binding(get: { currentClip.tempoRate }, set: { project.updateClip(currentClip, on: track, tempoRate: $0) })
    }

    private var pitchBinding: Binding<Int> {
        Binding(
            get: { currentClip.pitchSemitones },
            set: {
                project.setClipPitch($0, clipID: currentClip.id)
                timelineEngine.refreshPlaybackSchedule()
            }
        )
    }

    private var syncBinding: Binding<Bool> {
        Binding(
            get: { currentClip.syncToProject },
            set: { enabled in
                if enabled {
                    synchronizeTempo()
                } else {
                    project.updateClip(currentClip, on: track, syncToProject: false)
                    timelineEngine.refreshPlaybackSchedule()
                }
            }
        )
    }

    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func valueSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        valueText: String,
        disabled: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, onEditingChanged: { editing in
                if editing {
                    project.beginUndoCoalescing()
                } else {
                    project.endUndoCoalescing()
                    timelineEngine.refreshPlaybackSchedule()
                }
            })
            .disabled(disabled)
        }
    }

    private func refreshDrafts() {
        draftName = currentClip.name
        sourceBPMText = currentClip.sourceBPM.map { String(format: "%.1f", $0) } ?? ""
        errorMessage = nil
    }

    private func saveName() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { draftName = currentClip.name; return }
        project.updateClip(currentClip, on: track, name: name)
    }

    private func saveSourceBPM() {
        let raw = sourceBPMText.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            project.updateClip(currentClip, on: track, sourceBPM: .some(nil))
            timelineEngine.refreshPlaybackSchedule()
            errorMessage = nil
        } else if let value = Double(raw), value.isFinite, value > 0 {
            project.updateClip(currentClip, on: track, sourceBPM: .some(.some(value)))
            timelineEngine.refreshPlaybackSchedule()
            errorMessage = nil
        } else {
            errorMessage = "元BPMは0より大きい数値で入力してください。"
        }
    }

    private func synchronizeTempo() {
        let raw = sourceBPMText.trimmingCharacters(in: .whitespacesAndNewlines)
        let overrideBPM = raw.isEmpty ? nil : Double(raw)
        guard raw.isEmpty || (overrideBPM?.isFinite == true && (overrideBPM ?? 0) > 0) else {
            errorMessage = "元BPMは0より大きい数値で入力してください。"
            return
        }
        do {
            try project.syncClipTempo(clipId: currentClip.id, sourceBPM: overrideBPM)
            sourceBPMText = currentClip.sourceBPM.map { String(format: "%.1f", $0) } ?? ""
            timelineEngine.refreshPlaybackSchedule()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func matchKey() {
        do {
            try project.matchClipToProjectKey(clipID: currentClip.id)
            timelineEngine.refreshPlaybackSchedule()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func detectKey() {
        guard let snapshot = project.keyDetectionSnapshot(for: currentClip.id) else { return }
        let center = ActivityCenter.shared
        let activityID = center.begin(title: "キーを解析中", progress: nil)
        Task { @MainActor in
            defer { center.remove(activityID) }
            let result = await Task.detached(priority: .userInitiated) {
                KeyDetector.estimate(
                    fileURL: snapshot.sourceURL,
                    sourceStart: Double(bitPattern: snapshot.sourceStartBits),
                    duration: Double(bitPattern: snapshot.durationBits)
                )
            }.value
            if let result {
                if !project.setDetectedKey(result, matching: snapshot) {
                    errorMessage = "解析中に音源またはトリム範囲が変更されたため、結果を破棄しました。"
                } else {
                    errorMessage = nil
                }
            } else {
                errorMessage = "クリップのキーを推定できませんでした。"
            }
        }
    }
}
