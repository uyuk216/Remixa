import SwiftUI
import Sparkle
import UniformTypeIdentifiers

@main
struct RemixaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var project = RemixaProject()
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
                .frame(minWidth: 900, minHeight: 560)
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
            }
            CommandGroup(replacing: .undoRedo) {
                Button("元に戻す") { project.undo() }
                    .keyboardShortcut("z", modifiers: [.command])
                Button("やり直す") { project.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
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
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // See the `Window` vs `WindowGroup` comment above: this is a second line of
        // defense against Finder-open events spawning an extra tabbed window.
        NSWindow.allowsAutomaticWindowTabbing = false
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
    static let remixaSaveProject = Notification.Name("remixaSaveProject")
    static let remixaSaveProjectAs = Notification.Name("remixaSaveProjectAs")
}
