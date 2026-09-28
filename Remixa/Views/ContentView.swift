import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var document: AudioDocument
    @StateObject private var engine = AudioEngineController()
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
            if let error = document.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .padding()
            }
            if document.buffer != nil {
                WaveformView(engine: engine)
                    .frame(minHeight: 220)
                    .padding()
                TransportView(engine: engine)
                    .padding(.horizontal)
                Divider().padding(.vertical, 8)
                EffectsRackView()
                    .padding(.horizontal)
                Spacer(minLength: 8)
            } else {
                dropZone
            }
        }
        .onAppear {
            engine.attach(document: document)
        }
        .onChange(of: document.effects) { _, _ in engine.syncEffects() }
        .onChange(of: document.tempoPercent) { _, _ in engine.syncEffects() }
        .onChange(of: document.pitchSemitones) { _, _ in engine.syncEffects() }
        .onReceive(NotificationCenter.default.publisher(for: .remixaOpenFile)) { _ in
            openFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .remixaOpenDocument)) { notification in
            if let url = notification.userInfo?["url"] as? URL {
                document.load(url: url)
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ExportView(document: document)
        }
        .background(KeyEventHandlingView(onSpace: { engine.togglePlayPause() }))
    }

    private var toolbar: some View {
        HStack {
            Button {
                openFile()
            } label: {
                Label("開く", systemImage: "folder")
            }
            Spacer()
            if let bpm = document.estimatedBPM {
                Text("推定BPM: \(bpm, specifier: "%.1f")")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showExportSheet = true
            } label: {
                Label("書き出し", systemImage: "square.and.arrow.up")
            }
            .disabled(document.buffer == nil)
        }
        .padding()
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("音声ファイルをドラッグ＆ドロップ、または「開く」から選択")
                .foregroundStyle(.secondary)
            if document.isLoading {
                ProgressView("読み込み中…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDropTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url {
                Task { @MainActor in
                    document.load(url: url)
                }
            }
        }
        return true
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.supportedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            document.load(url: url)
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
