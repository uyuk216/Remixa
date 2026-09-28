import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var project: RemixaProject
    @StateObject private var timelineEngine = TimelineEngine()
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
            TimelineView(engine: timelineEngine)
                .environmentObject(project)
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDropOnEmptyArea(providers: providers)
                }
        }
        .onAppear {
            timelineEngine.attach(project: project)
        }
        .onChange(of: project.tracks.count) { _, _ in timelineEngine.rebuildGraph() }
        .onChange(of: project.masterVolume) { _, _ in timelineEngine.syncMixState() }
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
        .sheet(isPresented: $showExportSheet) {
            TimelineExportView(project: project)
        }
        .background(KeyEventHandlingView(onSpace: { timelineEngine.togglePlayPause() }))
    }

    private var toolbar: some View {
        HStack {
            Button { addAudioTrack() } label: {
                Label("音声を追加", systemImage: "waveform.badge.plus")
            }
            Button { openProjectPanel() } label: {
                Label("プロジェクトを開く", systemImage: "folder")
            }
            Button { saveProject(saveAs: false) } label: {
                Label("保存", systemImage: "square.and.arrow.down")
            }
            Spacer()
            Text(project.fileURL?.deletingPathExtension().lastPathComponent ?? "無題のプロジェクト")
                .foregroundStyle(.secondary)
            if project.isDirty {
                Text("•").foregroundStyle(.orange)
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.3")
                Slider(value: $project.masterVolume, in: 0...1.5)
                    .frame(width: 100)
            }
            Button {
                showExportSheet = true
            } label: {
                Label("ミックスを書き出し", systemImage: "square.and.arrow.up")
            }
            .disabled(project.projectDuration <= 0)
        }
        .padding()
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
            project.tracks = loaded.tracks
            project.bpm = loaded.bpm
            project.masterVolume = loaded.masterVolume
            project.fileURL = loaded.fileURL
            project.isDirty = false
            project.bufferCache = loaded.bufferCache
            timelineEngine.rebuildGraph()
        } catch {
            project.errorMessage = "プロジェクトを開けませんでした: \(error.localizedDescription)"
        }
    }

    private func saveProject(saveAs: Bool) {
        var destination = project.fileURL
        if saveAs || destination == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.remixaProject]
            panel.nameFieldStringValue = project.fileURL?.deletingPathExtension().lastPathComponent ?? "無題のプロジェクト"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        guard let destination else { return }
        do {
            try ProjectDocumentIO.save(project, to: destination)
        } catch {
            project.errorMessage = "保存に失敗しました: \(error.localizedDescription)"
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
