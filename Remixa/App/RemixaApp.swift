import SwiftUI
import Sparkle
import UniformTypeIdentifiers

@main
struct RemixaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var project = RemixaProject()
    @StateObject private var timelineEngine = TimelineEngine()
    @AppStorage("controlServerEnabled") private var controlServerEnabled: Bool = true
    private let updaterController: SPUStandardUpdaterController
    private let hasValidSparkleKey: Bool

    init() {
        let validKey = Self.hasValidSparklePublicKey()
        hasValidSparkleKey = validKey
        updaterController = SPUStandardUpdaterController(
            startingUpdater: validKey,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        configureAppDelegate()
    }

    /// Hands the updater controller to the AppDelegate (only when the updater
    /// was actually started, i.e. a valid Sparkle key is present) so it can
    /// kick off a background check-for-updates on every launch.
    private func configureAppDelegate() {
        if hasValidSparkleKey {
            appDelegate.updaterController = updaterController
        }
    }

    /// SUPublicEDKey is empty in local/Debug builds (SPARKLE_PUBLIC_KEY build
    /// setting isn't populated). Starting the updater with no valid key makes
    /// Sparkle show a "The updater failed to start" alert on launch, so we
    /// only start it when a plausible Ed25519 public key (32 bytes, base64) is present.
    private static func hasValidSparklePublicKey() -> Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty,
              let data = Data(base64Encoded: key) else {
            return false
        }
        return data.count == 32
    }

    var body: some Scene {
        // `Window` (rather than `WindowGroup`) guarantees the app has exactly one
        // window instance. With `WindowGroup`, a Finder "open" Apple Event could
        // cause SwiftUI to instantiate a second window/tab in addition to the
        // existing one that `AppDelegate.application(_:open:)` loads the file into;
        // `Window` makes that structurally impossible.
        Window("Remixa", id: "main") {
            ContentView()
                .environmentObject(project)
                .environmentObject(timelineEngine)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    timelineEngine.attach(project: project)
                    ControlServer.shared.attach(project: project, timelineEngine: timelineEngine)
                    if controlServerEnabled {
                        ControlServer.shared.start()
                    }
                }
                .onChange(of: controlServerEnabled) { _, enabled in
                    if enabled {
                        ControlServer.shared.start()
                    } else {
                        ControlServer.shared.stop()
                    }
                }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Remixaについて") {
                    NSApplication.shared.orderFrontStandardAboutPanel(nil)
                }
            }
            CommandGroup(after: .appInfo) {
                if hasValidSparkleKey {
                    Button("アップデートを確認…") {
                        updaterController.checkForUpdates(nil)
                    }
                }
                Button("Remixaを支援する…") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/sponsors/uyuk216")!)
                }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("元に戻す") {
                    project.undo()
                    timelineEngine.refreshPlaybackSchedule()
                }
                    .keyboardShortcut("z", modifiers: [.command])
                Button("やり直す") {
                    project.redo()
                    timelineEngine.refreshPlaybackSchedule()
                }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("新規プロジェクト") {
                    NotificationCenter.default.post(name: .remixaNewProject, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
                Button("音声ファイルを追加…") {
                    NotificationCenter.default.post(name: .remixaAddAudioTrack, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Button("プロジェクトを開く…") {
                    NotificationCenter.default.post(name: .remixaOpenProject, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
                Button("保存") {
                    NotificationCenter.default.post(name: .remixaSaveProject, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command])
                Button("別名で保存…") {
                    NotificationCenter.default.post(name: .remixaSaveProjectAs, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("編集") {
                Button("分割") { project.splitSelectedClips(at: timelineEngine.currentTime) }
                    .keyboardShortcut("b", modifiers: [.command])
                    .disabled(project.selectedClipIDs.isEmpty)
                Button("複製") { project.duplicateSelectedClips() }
                    .keyboardShortcut("d", modifiers: [.command])
                    .disabled(project.selectedClipIDs.isEmpty)
                Button("削除") { project.deleteSelectedClips() }
                    .keyboardShortcut(.delete)
                    .disabled(project.selectedClipIDs.isEmpty)
            }
            CommandMenu("タイムライン") {
                Button("拡大") { NotificationCenter.default.post(name: .remixaZoomIn, object: nil) }
                    .keyboardShortcut("+", modifiers: [.command])
                Button("縮小") { NotificationCenter.default.post(name: .remixaZoomOut, object: nil) }
                    .keyboardShortcut("-", modifiers: [.command])
                Divider()
                Button("全体を表示") { NotificationCenter.default.post(name: .remixaFitAll, object: nil) }
                    .keyboardShortcut("0", modifiers: [.command])
                Button("選択範囲に合わせる") { NotificationCenter.default.post(name: .remixaFitSelection, object: nil) }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
                    .disabled(project.selectedClipIDs.isEmpty)
                Button("再生位置へ移動") { NotificationCenter.default.post(name: .remixaScrollToPlayhead, object: nil) }
                    .keyboardShortcut("j", modifiers: [.command])
                Divider()
                Button("先頭へ移動") { NotificationCenter.default.post(name: .remixaGoToStart, object: nil) }
                    .keyboardShortcut(.home)
                Button("先頭へ移動") { NotificationCenter.default.post(name: .remixaGoToStart, object: nil) }
                    .keyboardShortcut(.return)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

/// App settings window (Remixa > 設定…). Currently just the control-server toggle;
/// grows here rather than in `ContentView` as more preferences are added.
struct SettingsView: View {
    @AppStorage("controlServerEnabled") private var controlServerEnabled: Bool = true

    var body: some View {
        Form {
            Toggle("外部からの操作を許可", isOn: $controlServerEnabled)
                .toggleStyle(.switch)
            Text("AIアシスタントや外部のCLIツールがRemixaを操作できるようにします(ローカルソケット経由)。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 8)

            StemEnvironmentSettingsSection()
        }
        .padding(20)
        .frame(width: 420)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `RemixaApp.init()` so we can trigger a background update check
    /// once per launch, in addition to Sparkle's own daily scheduled check.
    var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // See the `Window` vs `WindowGroup` comment above: this is a second line of
        // defense against Finder-open events spawning an extra tabbed window.
        NSWindow.allowsAutomaticWindowTabbing = false

        // Sparkle's SUScheduledCheckInterval only checks once every 24h, so an
        // app that isn't kept running continuously could go a long time between
        // checks. Force one check in the background on every launch as well.
        updaterController?.updater.checkForUpdatesInBackground()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Handles Finder "開く"/`open -a Remixa.app file.aiff` (or `.remixa` project)
    /// Apple Events. Loads into the existing window rather than creating a new one.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        NotificationCenter.default.post(name: .remixaOpenDocument, object: nil, userInfo: ["url": url])
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}

extension Notification.Name {
    static let remixaOpenDocument = Notification.Name("remixaOpenDocument")
    static let remixaAddAudioTrack = Notification.Name("remixaAddAudioTrack")
    static let remixaOpenProject = Notification.Name("remixaOpenProject")
    static let remixaNewProject = Notification.Name("remixaNewProject")
    static let remixaSaveProject = Notification.Name("remixaSaveProject")
    static let remixaSaveProjectAs = Notification.Name("remixaSaveProjectAs")
    static let remixaSeparateStems = Notification.Name("remixaSeparateStems")
    static let remixaZoomIn = Notification.Name("remixaZoomIn")
    static let remixaZoomOut = Notification.Name("remixaZoomOut")
    static let remixaFitAll = Notification.Name("remixaFitAll")
    static let remixaFitSelection = Notification.Name("remixaFitSelection")
    static let remixaScrollToPlayhead = Notification.Name("remixaScrollToPlayhead")
    static let remixaGoToStart = Notification.Name("remixaGoToStart")
}
