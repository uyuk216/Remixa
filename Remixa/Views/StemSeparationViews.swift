import SwiftUI

/// Drives the whole "パート分離" flow from the `.remixaSeparateStems` notification:
/// shows the install sheet if the environment isn't ready yet, then the progress sheet,
/// then calls `project.separateIntoStems(clipId:)`. Mounted once in `ContentView`.
struct StemSeparationFlow: View {
    @EnvironmentObject var project: RemixaProject
    @ObservedObject private var env = StemEnvironment.shared

    @State private var pendingClipId: UUID?
    @State private var showInstallSheet = false

    var body: some View {
        Color.clear
            .onReceive(NotificationCenter.default.publisher(for: .remixaSeparateStems)) { notification in
                guard let clipId = notification.userInfo?["clipId"] as? UUID else { return }
                pendingClipId = clipId
                if case .ready = env.status {
                    startSeparation(clipId: clipId)
                } else {
                    showInstallSheet = true
                }
            }
            .sheet(isPresented: $showInstallSheet) {
                StemInstallSheet(onInstalled: {
                    showInstallSheet = false
                    if let clipId = pendingClipId {
                        startSeparation(clipId: clipId)
                    }
                }, onCancel: {
                    showInstallSheet = false
                    pendingClipId = nil
                })
            }
    }

    private func startSeparation(clipId: UUID) {
        let center = ActivityCenter.shared
        let activityID = center.begin(title: "パート分離中", detail: "準備中…")
        let project = self.project
        let task = Task { @MainActor in
            do {
                _ = try await project.separateIntoStems(clipId: clipId) { fraction, message in
                    Task { @MainActor in center.update(activityID, progress: fraction, detail: message) }
                }
                center.finish(activityID, message: "パート分離完了")
            } catch is CancellationError {
                center.finish(activityID, message: "パート分離をキャンセルしました")
            } catch {
                center.remove(activityID)
                project.errorMessage = "パート分離に失敗しました: \(error.localizedDescription)"
            }
        }
        center.setCancel(activityID) { task.cancel() }
    }
}

/// Explains the ~1GB one-time download and drives `StemEnvironment.install`.
struct StemInstallSheet: View {
    @ObservedObject private var env = StemEnvironment.shared
    let onInstalled: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AIパート分離を準備").font(.title2)
            Text("初回のみ、ボーカル・ドラム・ベースなどにパートを分離するためのAIモデル(約1GB)をダウンロードします。以降はオフラインで利用できます。")
                .font(.callout)
                .foregroundStyle(.secondary)

            if case .installing(let progress, let message) = env.status {
                ProgressView(value: progress)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if case .failed(let message) = env.status {
                Text("失敗しました: \(message)").foregroundStyle(.red).font(.caption)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(env.log.enumerated()), id: \.offset) { index, line in
                            Text(line).font(.system(.caption2, design: .monospaced)).id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
                .background(Color.black.opacity(0.04))
                .onChange(of: env.log.count) { _, _ in
                    if let last = env.log.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }

            HStack {
                Button("キャンセル") {
                    env.cancelInstall()
                    onCancel()
                }
                Spacer()
                if case .installing = env.status {
                    ProgressView().controlSize(.small)
                } else {
                    Button("インストール") {
                        Task {
                            await env.install { _, _ in }
                            if case .ready = env.status {
                                onInstalled()
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .onChange(of: env.status) { _, newValue in
            if case .ready = newValue { onInstalled() }
        }
    }
}

/// Shown while `StemSeparationService` is running for a clip.
struct StemProgressSheet: View {
    let progress: Double
    let message: String
    let errorMessage: String?
    let onCancel: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("パート分離中…").font(.title2)
            if let errorMessage {
                Text("失敗しました: \(errorMessage)").foregroundStyle(.red)
                Button("閉じる") { onDismiss() }
            } else {
                ProgressView(value: progress)
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("キャンセル") { onCancel() }
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

/// Section embedded in `SettingsView`: status, size, reinstall/delete.
struct StemEnvironmentSettingsSection: View {
    @ObservedObject private var env = StemEnvironment.shared
    @State private var showInstallSheet = false
    @State private var sizeText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AIパート分離").font(.headline)

            HStack {
                Text("状態:")
                Text(statusLabel).foregroundStyle(.secondary)
            }
            if case .ready = env.status {
                HStack {
                    Text("使用容量:")
                    Text(sizeText).foregroundStyle(.secondary)
                }
            }

            HStack {
                switch env.status {
                case .notInstalled, .failed:
                    Button("インストール") { showInstallSheet = true }
                case .installing:
                    ProgressView().controlSize(.small)
                    Button("キャンセル") { env.cancelInstall() }
                case .ready:
                    Button("再インストール") {
                        Task { await env.reinstall { _, _ in }; refreshSize() }
                    }
                    Button("削除", role: .destructive) {
                        try? env.uninstall()
                        refreshSize()
                    }
                }
            }
        }
        .onAppear { refreshSize() }
        .sheet(isPresented: $showInstallSheet) {
            StemInstallSheet(onInstalled: { showInstallSheet = false; refreshSize() }, onCancel: { showInstallSheet = false })
        }
    }

    private var statusLabel: String {
        switch env.status {
        case .notInstalled: return "未インストール"
        case .installing(let progress, let message): return "インストール中 (\(Int(progress * 100))%) \(message)"
        case .ready: return "利用可能"
        case .failed(let message): return "失敗: \(message)"
        }
    }

    private func refreshSize() {
        let bytes = env.installedSizeBytes()
        sizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
