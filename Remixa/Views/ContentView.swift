import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var project: RemixaProject
    @EnvironmentObject var timelineEngine: TimelineEngine
    @State private var showAIPanel = false
    @State private var showExportSheet = false
    @State private var isDropTargeted = false

    private static let supportedTypes: [UTType] = [
        .mp3, .mpeg4Audio, .wav, .aiff,
        UTType(filenameExtension: "flac") ?? .audio
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = project.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .padding(6)
            }
            HStack(spacing: 0) {
                TimelineView(engine: timelineEngine)
                    .environmentObject(project)
                    .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                        handleDropOnEmptyArea(providers: providers)
                    }
                if showAIPanel {
                    Divider()
                    AIAssistantPanel()
                        .frame(width: 340)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear {
            timelineEngine.attach(project: project)
        }
        .onChange(of: project.tracks.count) { _, _ in timelineEngine.rebuildGraph() }
        .onChange(of: project.mixStateRevision) { _, _ in timelineEngine.syncMixState() }
        .onReceive(NotificationCenter.default.publisher(for: .remixaAddAudioTrack)) { _ in
            addAudioTrack()
        }
        .onReceive(NotificationCenter.default.publisher(for: .remixaOpenDocument)) { notification in
            if let url = notification.userInfo?["url"] as? URL {
                if url.pathExtension.lowercased() == "remixa" {
                    openProject(at: url)
                } else {
                    project.addTrackOrFillFirstEmpty(named: url.deletingPathExtension().lastPathComponent, audioURL: url)
                }
            }
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
        .sheet(isPresented: $showExportSheet) {
            TimelineExportView(project: project)
        }
        .background(KeyEventHandlingView(onSpace: { timelineEngine.togglePlayPause() }))
        .background(StemSeparationFlow())
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            toolbarContent(compact: false, showVolume: true)
            toolbarContent(compact: true, showVolume: true)
            toolbarContent(compact: true, showVolume: false)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func toolbarButton(_ title: String, _ icon: String, compact: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if compact {
                Label(title, systemImage: icon).labelStyle(.iconOnly)
            } else {
                Label(title, systemImage: icon).lineLimit(1).fixedSize()
            }
        }
        .help(title)
    }

    private func toolbarContent(compact: Bool, showVolume: Bool) -> some View {
        HStack {
            toolbarButton("音声を追加", "waveform.badge.plus", compact: compact) { addAudioTrack() }
            toolbarButton("プロジェクトを開く", "folder", compact: compact) { openProjectPanel() }
            toolbarButton("保存", "square.and.arrow.down", compact: compact) { saveProject(saveAs: false) }
            Spacer(minLength: 8)
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
            Spacer(minLength: 8)
            if showVolume {
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
            toolbarButton("ミックスを書き出し", "square.and.arrow.up", compact: compact) { showExportSheet = true }
                .disabled(project.projectDuration <= 0)
            toolbarButton("パート分離", "waveform.and.mic", compact: compact) {
                if let clipId = project.selectedClipID {
                    NotificationCenter.default.post(name: .remixaSeparateStems, object: nil, userInfo: ["clipId": clipId])
                }
            }
            .disabled(project.selectedClipID == nil)
            toolbarButton("AIアシスタント", "sparkles", compact: compact) {
                withAnimation { showAIPanel.toggle() }
            }
        }
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
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                _ = project.addTrackOrFillFirstEmpty(named: url.deletingPathExtension().lastPathComponent, audioURL: url)
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
