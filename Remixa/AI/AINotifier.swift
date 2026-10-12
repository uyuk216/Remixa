import Foundation
import AppKit
@preconcurrency import UserNotifications

enum AINotifyMode: String, CaseIterable, Identifiable {
    case always, background, never
    var id: String { rawValue }
    var label: String {
        switch self {
        case .always: return "常に"
        case .background: return "アプリが裏にあるときだけ"
        case .never: return "しない"
        }
    }
}

/// Completion notifications (AI replies, export, stem separation) via UNUserNotificationCenter.
@MainActor
final class AINotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AINotifier()
    nonisolated static let modeKey = "aiNotifyMode"
    nonisolated static let soundKey = "aiNotifySound"
    nonisolated static let chatIDKey = "chatID"

    @Published private(set) var status: UNAuthorizationStatus = .notDetermined

    static var mode: AINotifyMode {
        AINotifyMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .background
    }

    static var soundEnabled: Bool {
        UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true
    }

    func install() {
        UNUserNotificationCenter.current().delegate = self
        refreshStatus()
    }

    func refreshStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let s = settings.authorizationStatus
            Task { @MainActor in AINotifier.shared.status = s }
        }
    }

    /// Asks for permission (no-op unless not yet determined).
    func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in AINotifier.shared.refreshStatus() }
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func shouldNotify() -> Bool {
        switch Self.mode {
        case .never: return false
        case .always: return true
        case .background: return !NSApp.isActive
        }
    }

    /// AI reply finished (or failed). `body` is truncated to ~80 chars.
    func notifyAIFinished(chatID: UUID, text: String, isError: Bool) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        var body = clean.isEmpty ? (isError ? "エラーが発生しました" : "応答が完了しました") : clean
        if body.count > 80 { body = String(body.prefix(80)) + "…" }
        if isError { body = "エラー: " + body }
        post(title: "Remixa AIアシスタント", body: body, userInfo: [Self.chatIDKey: chatID.uuidString])
    }

    /// Export / stem separation completion.
    func notifyTask(_ message: String) {
        post(title: "Remixa", body: message, userInfo: [:])
    }

    private func post(title: String, body: String, userInfo: [String: String]) {
        guard shouldNotify() else { return }
        let center = UNUserNotificationCenter.current()
        let sound = Self.soundEnabled
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { Self.deliver(title: title, body: body, userInfo: userInfo, sound: sound) }
                    Task { @MainActor in AINotifier.shared.refreshStatus() }
                }
            case .denied:
                Task { @MainActor in AINotifier.shared.refreshStatus() }
            default:
                Self.deliver(title: title, body: body, userInfo: userInfo, sound: sound)
            }
        }
    }

    nonisolated private static func deliver(title: String, body: String, userInfo: [String: String], sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = userInfo
        if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let idString = response.notification.request.content.userInfo[Self.chatIDKey] as? String
        completionHandler()
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            if let idString, let id = UUID(uuidString: idString) {
                ChatStore.shared.pendingOpenID = id
            }
        }
    }
}
