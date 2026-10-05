import SwiftUI
import UniformTypeIdentifiers

private enum ContentSheet: String, Identifiable {
    case export
    case shortcuts

    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var project: RemixaProject
    @EnvironmentObject var timelineEngine: TimelineEngine
    @State private var showAIPanel = false
    @State private var showClipInspector = false
    @State private var activeSheet: ContentSheet?
    @State private var isDropTargeted = false
    @State private var usesBarsPosition = true

    private static let supportedTypes: [UTType] = [
        .mp3, .mpeg4Audio, .wav, .aiff,
        UTType(filenameExtension: "flac") ?? .audio
    ]

    var body: some View {
        presentedContent
            .background(KeyEventHandlingView(onSpace: { timelineEngine.togglePlayPause() }))
            .background(StemSeparationFlow())
    }

    private var presentedContent: some View {
        notificationContent
            .sheet(item: $activeSheet) { sheet in
                sheetView(for: sheet)
            }
    }

    private var notificationContent: some View {
        observedContent
            .onReceive(NotificationCenter.default.publisher(for: .remixaAddAudioTrack)) { _ in
                addAudioTrack()
            }
            .onReceive(NotificationCenter.default.publisher(for: .remixaOpenDocument)) { notification in
                openDocument(from: notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .remixaSaveProject)) { _ in
                saveProject(saveAs: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: .remixaSaveProjectAs)) { _ in
                saveProject(saveAs: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .remixaOpenProject)) { _ in
                openProjectPanel()
            }
            .onReceive(NotificationCenter.default.publisher(for: .remixaNewProject)) { _ in
                newProjectFromUI()
            }
            .onReceive(NotificationCenter.default.publisher(for: .remixaToggleInspector)) { _ in
                toggleInspector()
            }
            .onReceive(NotificationCenter.default.publisher(for: .remixaShowShortcuts)) { _ in
                activeSheet = .shortcuts
            }
    }

    private var observedContent: some View {
        mainLayout
            .frame(minWidth: 560, minHeight: 420)
            .onAppear {
                timelineEngine.attach(project: project)
            }
            .onChange(of: project.tracks.count) { _, _ in timelineEngine.rebuildGraph() }
            .onChange(of: project.mixStateRevision) { _, _ in timelineEngine.syncMixState() }
            .onChange(of: project.bpm) { _, _ in timelineEngine.refreshPlaybackSchedule() }
            .onChange(of: project.playbackMetronomeEnabled) { _, _ in timelineEngine.refreshMetronomeSettings() }
            .onChange(of: project.metronomeVolume) { _, _ in timelineEngine.refreshMetronomeSettings() }
            .onChange(of: project.timeSignature) { _, _ in timelineEngine.refreshMetronomeSettings() }
    }

    private var mainLayout: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            errorMessage
            workspace
            Divider()
            TransportBar(engine: timelineEngine, usesBarsPosition: $usesBarsPosition)
        }
    }

    @ViewBuilder
    private var errorMessage: some View {
        if let error = project.errorMessage {
            Text(error)
                .foregroundStyle(.red)
                .padding(6)
        }
    }

    private var workspace: some View {
        HStack(spacing: 0) {
            timeline
            sidePanel
        }
    }

    private var timeline: some View {
        TimelineView(engine: timelineEngine)
            .environmentObject(project)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDropOnEmptyArea(providers: providers)
            }
    }

    @ViewBuilder
    private var sidePanel: some View {
        if showClipInspector {
            Divider()
            clipInspector
        } else if showAIPanel {
            Divider()
            AIAssistantPanel()
                .frame(width: 340)
                .transition(.move(edge: .trailing))
        }
    }

    @ViewBuilder
    private var clipInspector: some View {
        if let (clip, track) = selectedClipAndTrack() {
            ClipInspectorView(project: project, track: track, clip: clip, timelineEngine: timelineEngine)
                .frame(width: 280)
                .id(clip.id)
        } else {
            emptyInspector
        }
    }

    private var emptyInspector: some View {
        VStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("クリップを選択すると、ここで詳細を編集できます")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 280)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func sheetView(for sheet: ContentSheet) -> some View {
        switch sheet {
        case .export:
            TimelineExportView(project: project)
        case .shortcuts:
            KeyboardShortcutsView()
                .frame(width: 460, height: 470)
        }
    }

    private func openDocument(from notification: Notification) {
        guard let url = notification.userInfo?["url"] as? URL else { return }
        if url.pathExtension.lowercased() == "remixa" {
            openProject(at: url)
        } else {
            project.addTrackOrFillFirstEmpty(named: url.deletingPathExtension().lastPathComponent, audioURL: url)
        }
    }

    private func toggleInspector() {
        withAnimation {
            showClipInspector.toggle()
            if showClipInspector { showAIPanel = false }
        }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            toolbarContent(compact: false, showVolume: true)
            toolbarContent(compact: false, showVolume: false)
            toolbarContent(compact: true, showVolume: true)
            toolbarContent(compact: true, showVolume: false)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func toolbarButton(_ title: String, label: String, _ icon: String, compact: Bool, help: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if compact {
                Label(title, systemImage: icon).labelStyle(.iconOnly)
            } else {
                Label(label, systemImage: icon).lineLimit(1).fixedSize()
            }
        }
        .help(help ?? title)
    }

    private func toolbarContent(compact: Bool, showVolume: Bool) -> some View {
        HStack {
            fileToolbarButtons(compact: compact)
            Spacer(minLength: 8)
            projectTitle
            Spacer(minLength: 8)
            if showVolume { volumeControl }
            projectToolbarButtons(compact: compact)
        }
    }

    private func fileToolbarButtons(compact: Bool) -> some View {
        Group {
            toolbarButton("音声を追加", label: "追加", "waveform.badge.plus", compact: compact) { addAudioTrack() }
            toolbarButton("プロジェクトを開く", label: "開く", "folder", compact: compact) { openProjectPanel() }
            toolbarButton("保存", label: "保存", "square.and.arrow.down", compact: compact) { saveProject(saveAs: false) }
        }
    }

    private var projectTitle: some View {
        HStack(spacing: 4) {
            Text(project.fileURL?.deletingPathExtension().lastPathComponent ?? "無題のプロジェクト")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if project.isDirty {
                Text("•").foregroundStyle(.orange)
            }
        }
        .layoutPriority(-1)
    }

    private var volumeControl: some View {
        HStack(spacing: 4) {
            Image(systemName: "speaker.wave.3")
            Slider(
                value: Binding(get: { project.masterVolume }, set: { project.setMasterVolume($0) }),
                in: 0...1.5,
                onEditingChanged: { editing in
                    if editing { project.beginUndoCoalescing() } else { project.endUndoCoalescing() }
                }
            )
            .frame(width: 100)
        }
    }

    private func projectToolbarButtons(compact: Bool) -> some View {
        Group {
            toolbarButton("ミックスを書き出し", label: "書き出し", "square.and.arrow.up", compact: compact) { activeSheet = .export }
                .disabled(project.projectDuration <= 0)
            toolbarButton("パート分離", label: "パート分離", "waveform.and.mic", compact: compact, help: project.selectedClipID == nil ? "クリップを選択すると使えます" : "選択中のクリップをパートに分離") {
                if let clipId = project.selectedClipID {
                    NotificationCenter.default.post(name: .remixaSeparateStems, object: nil, userInfo: ["clipId": clipId])
                }
            }
            .disabled(project.selectedClipID == nil)
            toolbarButton("AIアシスタント", label: "AI", "sparkles", compact: compact) {
                withAnimation {
                    showAIPanel.toggle()
                    if showAIPanel { showClipInspector = false }
                }
            }
            toolbarButton("インスペクタ", label: "インスペクタ", "sidebar.right", compact: compact) {
                toggleInspector()
            }
        }
    }

    private func selectedClipAndTrack() -> (Clip, Track)? {
        guard let selectedID = project.selectedClipID else { return nil }
        for track in project.tracks {
            if let clip = track.clips.first(where: { $0.id == selectedID }) { return (clip, track) }
        }
        return nil
    }

    private func addAudioTrack() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.supportedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for url in panel.urls {
                project.addTrackOrFillFirstEmpty(named: url.deletingPathExtension().lastPathComponent, audioURL: url)
            }
        }
    }

    private func handleDropOnEmptyArea(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    _ = project.addTrackOrFillFirstEmpty(named: url.deletingPathExtension().lastPathComponent, audioURL: url)
                }
            }
        }
        return true
    }

    private func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.remixaProject]
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            openProject(at: url)
        }
    }

    private func openProject(at url: URL) {
        do {
            let loaded = try ProjectDocumentIO.load(from: url)
            guard confirmUnsavedChangesBeforeSwitch() else { return }
            project.replaceContents(with: loaded)
            timelineEngine.rebuildGraph()
        } catch {
            project.errorMessage = "プロジェクトを開けませんでした: \(error.localizedDescription)"
        }
    }

    private func newProjectFromUI() {
        guard confirmUnsavedChangesBeforeSwitch() else { return }
        project.resetForNewProject()
        timelineEngine.rebuildGraph()
    }

    private func confirmUnsavedChangesBeforeSwitch() -> Bool {
        guard project.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "保存していない変更があります"
        alert.informativeText = "プロジェクトを切り替える前に変更を保存しますか？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "保存しない")
        alert.addButton(withTitle: "キャンセル")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveProject(saveAs: false)
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    @discardableResult
    private func saveProject(saveAs: Bool) -> Bool {
        var destination = project.fileURL
        if saveAs || destination == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.remixaProject]
            panel.nameFieldStringValue = project.fileURL?.deletingPathExtension().lastPathComponent ?? "無題のプロジェクト"
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            destination = url
        }
        guard let destination else { return false }
        do {
            try ProjectDocumentIO.save(project, to: destination)
            project.errorMessage = nil
            return true
        } catch {
            project.errorMessage = "保存に失敗しました: \(error.localizedDescription)"
            return false
        }
    }
}

/// Minimal helper to capture the space bar for play/pause anywhere in the window.
struct KeyEventHandlingView: NSViewRepresentable {
    let onSpace: () -> Void

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.onSpace = onSpace
        return view
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.onSpace = onSpace
    }

    final class KeyCatcherView: NSView {
        var onSpace: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 49 { // space
                onSpace?()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

private struct TransportBar: View {
    @EnvironmentObject var project: RemixaProject
    @ObservedObject var engine: TimelineEngine
    @Binding var usesBarsPosition: Bool

    private var bpmBinding: Binding<Double> {
        Binding(get: { project.bpm }, set: { project.setBPM($0) })
    }

    private var signatureBinding: Binding<TimeSignature> {
        Binding(get: { project.timeSignature }, set: { project.setTimelineSettings(timeSignature: $0) })
    }

    private var keyBinding: Binding<MusicalKey?> {
        Binding(get: { project.projectKey }, set: { project.setProjectKey($0) })
    }

    private var loopBinding: Binding<Bool> {
        Binding(
            get: { project.loopRegion != nil },
            set: { enabled in
                if enabled {
                    let barLength = 60.0 / max(1, project.bpm) * Double(project.beatsPerBar)
                    let start = max(0, engine.currentTime)
                    project.loopRegion = start...(start + barLength)
                } else {
                    project.loopRegion = nil
                }
            }
        )
    }

    private var metronomeBinding: Binding<Bool> {
        Binding(
            get: { project.playbackMetronomeEnabled },
            set: { project.setMetronomeSettings(playbackEnabled: $0) }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            playbackControls
            loopToggle
            metronomeToggle
            positionDisplay
            Divider().frame(height: 26)
            bpmControl
            timeSignatureMenu
            keyMenu
            Spacer(minLength: 0)
            ActivityStrip()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var playbackControls: some View {
        HStack(spacing: 4) {
            transportButton("先頭へ", icon: "backward.end.fill") {
                NotificationCenter.default.post(name: .remixaGoToStart, object: nil)
            }
            transportButton(engine.isPlaying ? "一時停止" : "再生", icon: engine.isPlaying ? "pause.fill" : "play.fill", prominent: true) {
                engine.togglePlayPause()
            }
            transportButton("停止", icon: "stop.fill") {
                engine.stop()
                NotificationCenter.default.post(name: .remixaGoToStart, object: nil)
            }
        }
    }

    private var loopToggle: some View {
        Toggle(isOn: loopBinding) {
            Image(systemName: "repeat")
        }
        .toggleStyle(.button)
        .tint(project.loopRegion == nil ? .secondary : .orange)
        .help("ループ再生")
    }

    private var metronomeToggle: some View {
        Toggle(isOn: metronomeBinding) {
            Image(systemName: "metronome")
        }
        .toggleStyle(.button)
        .tint(project.playbackMetronomeEnabled ? .orange : .secondary)
        .help("再生時のメトロノーム")
    }

    private var positionDisplay: some View {
        Button {
            usesBarsPosition.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(usesBarsPosition ? "小節.拍.tick" : "分:秒")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(usesBarsPosition ? barsPosition(engine.currentTime) : secondsPosition(engine.currentTime))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(width: 92, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help("クリックして小節表示と時間表示を切り替え")
    }

    private var bpmControl: some View {
        HStack(spacing: 5) {
            Text("BPM").font(.caption).foregroundStyle(.secondary)
            TextField("BPM", value: bpmBinding, format: .number.precision(.fractionLength(0...1)))
                .frame(width: 54)
                .textFieldStyle(.roundedBorder)
                .help("プロジェクトのテンポ (20〜400 BPM)")
        }
    }

    private var timeSignatureMenu: some View {
        Menu {
            Picker("拍子", selection: signatureBinding) {
                ForEach(TimeSignature.allCases) { signature in
                    Text(signature.rawValue).tag(signature)
                }
            }
        } label: {
            Label(project.timeSignature.rawValue, systemImage: "music.note")
                .lineLimit(1)
        }
        .help("拍子")
    }

    private var keyMenu: some View {
        Menu {
            Picker("プロジェクトのキー", selection: keyBinding) {
                Text("未設定").tag(nil as MusicalKey?)
                ForEach(MusicalKey.all) { key in
                    Text(key.displayName).tag(Optional(key))
                }
            }
        } label: {
            Label(project.projectKey?.name ?? "キー未設定", systemImage: "music.note.list")
                .lineLimit(1)
        }
        .help("プロジェクトのキー")
    }

    private func transportButton(
        _ title: String,
        icon: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: prominent ? 30 : 25, height: 26)
                .background(prominent ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func barsPosition(_ seconds: Double) -> String {
        let beatLength = 60.0 / max(1, project.bpm)
        let totalBeats = max(0, seconds) / beatLength
        let completedBeats = Int(totalBeats)
        let bar = completedBeats / max(1, project.beatsPerBar) + 1
        let beat = completedBeats % max(1, project.beatsPerBar) + 1
        let tick = Int((totalBeats - Double(completedBeats)) * 960)
        return String(format: "%d.%d.%03d", bar, beat, tick)
    }

    private func secondsPosition(_ seconds: Double) -> String {
        let safe = max(0, seconds)
        let minute = Int(safe) / 60
        return String(format: "%02d:%04.1f", minute, safe.truncatingRemainder(dividingBy: 60))
    }
}

private struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private let shortcuts: [(String, String)] = [
        ("再生 / 一時停止", "Space"),
        ("先頭へ移動", "Home / Return"),
        ("分割", "⌘B"),
        ("複製", "⌘D"),
        ("削除", "Delete"),
        ("拡大 / 縮小", "⌘+ / ⌘−"),
        ("全体を表示", "⌘0"),
        ("選択範囲に合わせる", "⇧⌘0"),
        ("再生位置へ移動", "⌘J"),
        ("インスペクタの表示切替", "⌘⌥I"),
        ("元に戻す / やり直す", "⌘Z / ⇧⌘Z"),
        ("保存", "⌘S"),
        ("別名で保存", "⇧⌘S"),
        ("プロジェクトを開く", "⌘O"),
        ("音声ファイルを追加", "⇧⌘O")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("キーボードショートカット")
                .font(.title2.bold())
                .padding(.bottom, 12)
            Divider()
            shortcutList
            dismissButton
        }
        .padding(20)
    }

    private var shortcutList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(shortcuts.enumerated()), id: \.offset) { row in
                    shortcutRow(row.element)
                }
            }
        }
        .padding(.top, 4)
    }

    private func shortcutRow(_ shortcut: (String, String)) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(shortcut.0)
                Spacer()
                Text(shortcut.1)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 7)
            Divider()
        }
    }

    private var dismissButton: some View {
        HStack {
            Spacer()
            Button("閉じる") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.top, 12)
    }
}
