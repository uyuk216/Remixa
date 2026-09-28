import SwiftUI
import Sparkle

@main
struct RemixaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var document = AudioDocument()
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
        WindowGroup {
            ContentView()
                .environmentObject(document)
                .frame(minWidth: 900, minHeight: 600)
        }
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
                Button("元に戻す") { document.undo() }
                    .keyboardShortcut("z", modifiers: [.command])
                Button("やり直す") { document.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("音声ファイルを開く…") {
                    NotificationCenter.default.post(name: .remixaOpenFile, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Handles Finder "開く"/`open -a Remixa.app file.aiff` Apple Events.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        NotificationCenter.default.post(name: .remixaOpenDocument, object: nil, userInfo: ["url": url])
    }
}

extension Notification.Name {
    static let remixaOpenFile = Notification.Name("remixaOpenFile")
    static let remixaOpenDocument = Notification.Name("remixaOpenDocument")
}
