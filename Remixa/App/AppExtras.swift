import SwiftUI
import AppKit

extension Notification.Name {
    static let remixaShowGuide = Notification.Name("remixaShowGuide")
}

// MARK: - First-launch guide

struct GuideView: View {
    @AppStorage("hideUsageGuide") private var hideGuide = false
    @Environment(\.dismiss) private var dismiss

    private let steps: [(icon: String, title: String, text: String)] = [
        ("plus.circle", "1. ファイルを追加", "音声ファイルをウィンドウにドラッグ&ドロップするか、ファイル > 音声ファイルを追加 で読み込みます。"),
        ("waveform.path", "2. パート分離・テンポ合わせ", "クリップを右クリックして「パート分離」や「BPMに合わせる」「キーを合わせる」を選ぶと、曲を重ねやすく整えられます。"),
        ("square.and.arrow.up", "3. 書き出し", "仕上がったら書き出しボタンからオーディオファイルとして保存します。プロジェクトの保存は ⌘S です。")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remixaの使い方").font(.title2.bold())
            ForEach(steps, id: \.title) { step in
                GuideStepRow(icon: step.icon, title: step.title, text: step.text)
            }
            Divider()
            HStack {
                Toggle("次回から表示しない", isOn: $hideGuide)
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

private struct GuideStepRow: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Recent projects menu

struct RecentProjectsMenu: View {
    @ObservedObject var project: RemixaProject

    var body: some View {
        let urls = NSDocumentController.shared.recentDocumentURLs
            .filter { $0.pathExtension.lowercased() == "remixa" }
        Menu("最近使ったプロジェクト") {
            if urls.isEmpty {
                Text("なし")
            }
            ForEach(urls, id: \.self) { url in
                Button(url.deletingPathExtension().lastPathComponent) {
                    NotificationCenter.default.post(name: .remixaOpenDocument, object: nil, userInfo: ["url": url])
                }
            }
            Divider()
            Button("メニューを消去") {
                NSDocumentController.shared.clearRecentDocuments(nil)
                project.objectWillChange.send()
            }
            .disabled(urls.isEmpty)
        }
    }
}

// MARK: - Autosave

@MainActor
final class AutosaveManager {
    static let shared = AutosaveManager()

    private weak var project: RemixaProject?
    private weak var engine: TimelineEngine?
    private var timer: Timer?
    private let originalKey = "autosaveOriginalPath"

    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Remixa/Autosave", isDirectory: true)
    }
    private var backupURL: URL { directory.appendingPathComponent("Backup.remixa", isDirectory: true) }

    func start(project: RemixaProject, engine: TimelineEngine) {
        guard timer == nil else { return }
        self.project = project
        self.engine = engine
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in AutosaveManager.shared.tick() }
        }
    }

    /// Called every 60 s: back up when dirty, drop the backup when clean.
    func tick() {
        guard let project else { return }
        if project.isDirty { writeBackup(of: project) } else { removeBackup() }
    }

    func removeBackup() {
        try? FileManager.default.removeItem(at: backupURL)
        UserDefaults.standard.removeObject(forKey: originalKey)
    }

    /// Normal quit: a clean project needs no backup; a dirty one keeps it for restoring.
    func willTerminate() {
        if let project, project.isDirty { writeBackup(of: project) } else { removeBackup() }
        UserDefaults.standard.set(Date(), forKey: "lastCleanExit")
    }

    private func writeBackup(of project: RemixaProject) {
        let copy = RemixaProject()
        copy.tracks = project.tracks.map { $0.copy() }
        copy.bpm = project.bpm
        copy.masterVolume = project.masterVolume
        copy.markers = project.markers
        copy.snapDivision = project.snapDivision
        copy.timeSignature = project.timeSignature
        copy.playbackMetronomeEnabled = project.playbackMetronomeEnabled
        copy.exportMetronomeEnabled = project.exportMetronomeEnabled
        copy.metronomeVolume = project.metronomeVolume
        copy.countInEnabled = project.countInEnabled
        copy.projectKey = project.projectKey
        copy.fileURL = project.fileURL
        do {
            try ProjectDocumentIO.save(copy, to: backupURL, updateProjectState: false)
            UserDefaults.standard.set(project.fileURL?.path ?? "", forKey: originalKey)
        } catch {
            // Autosave is best-effort; never interrupt the user.
        }
    }

    /// On launch: offer to restore a backup left behind by a crash / unsaved quit.
    func offerRestoreIfNeeded() -> Bool {
        let fm = FileManager.default
        guard let project, let engine,
              let attrs = try? fm.attributesOfItem(atPath: backupURL.path),
              let modified = attrs[.modificationDate] as? Date else { return false }
        if let lastExit = UserDefaults.standard.object(forKey: "lastCleanExit") as? Date,
           modified < lastExit, !UserDefaults.standard.bool(forKey: "autosaveForce") {
            // Backup predates the last clean exit; but a dirty quit keeps its backup, so
            // only discard when nothing newer exists.
            if UserDefaults.standard.string(forKey: originalKey) == nil { removeBackup(); return false }
        }
        let alert = NSAlert()
        alert.messageText = "前回の作業を復元しますか？"
        alert.informativeText = "保存されていない作業の自動バックアップが見つかりました。"
        alert.addButton(withTitle: "復元")
        alert.addButton(withTitle: "破棄")
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                let loaded = try ProjectDocumentIO.load(from: backupURL)
                let original = UserDefaults.standard.string(forKey: originalKey) ?? ""
                project.replaceContents(with: loaded)
                project.fileURL = original.isEmpty ? nil : URL(fileURLWithPath: original)
                project.isDirty = true
                engine.rebuildGraph()
            } catch {
                project.errorMessage = "バックアップを復元できませんでした: \(error.localizedDescription)"
            }
        } else {
            removeBackup()
        }
        return true
    }
}

// MARK: - Window hook (guide sheet + autosave + restore)

struct AppExtrasModifier: ViewModifier {
    @ObservedObject var project: RemixaProject
    let engine: TimelineEngine
    @AppStorage("hideUsageGuide") private var hideGuide = false
    @State private var showGuide = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showGuide) { GuideView() }
            .onReceive(NotificationCenter.default.publisher(for: .remixaShowGuide)) { _ in
                showGuide = true
            }
            .onChange(of: project.isDirty) { _, dirty in
                if !dirty { AutosaveManager.shared.removeBackup() }
            }
            .task {
                AutosaveManager.shared.start(project: project, engine: engine)
                try? await Task.sleep(nanoseconds: 600_000_000)
                let restoreAsked = AutosaveManager.shared.offerRestoreIfNeeded()
                if !restoreAsked && !hideGuide { showGuide = true }
            }
    }
}
