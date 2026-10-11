import SwiftUI

/// Sign in with ChatGPT section shown in the AI assistant panel header.
struct ChatGPTAccountView: View {
    @ObservedObject var auth: ChatGPTAuth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if auth.isSignedIn {
                SignedInSection(auth: auth)
            } else if auth.isSigningIn {
                SigningInSection(auth: auth)
            } else {
                SignedOutSection(auth: auth)
            }
            if let error = auth.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SignedOutSection: View {
    @ObservedObject var auth: ChatGPTAuth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("お使いのChatGPTプラン(Plus/Pro)でAIアシスタントを使えます")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                auth.signIn()
            } label: {
                Label("ChatGPTで続ける", systemImage: "bubble.left.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.black)
            .controlSize(.large)
        }
    }
}

private struct SigningInSection: View {
    @ObservedObject var auth: ChatGPTAuth

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
            Text("ブラウザでサインインしてください…")
                .font(.caption)
            Spacer()
            Button("キャンセル") { auth.cancelSignIn() }
        }
    }
}

private struct SignedInSection: View {
    @ObservedObject var auth: ChatGPTAuth

    private var modelBinding: Binding<String> {
        Binding(get: { auth.selectedModel ?? "" }, set: { auth.selectModel($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(auth.email ?? "ChatGPTアカウント")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("接続済み").font(.caption2).foregroundStyle(.secondary)
            }
            Text(auth.planAvailable ? "プランの利用: 可能" : "プランの利用: 不可(サインインし直してください)")
                .font(.caption2)
                .foregroundStyle(auth.planAvailable ? Color.secondary : Color.orange)
            if !auth.models.isEmpty {
                Picker("モデル", selection: modelBinding) {
                    ForEach(auth.models) { model in
                        Text(model.displayName).tag(model.slug)
                    }
                }
                .font(.caption)
            }
            HStack {
                Button("使用量を管理") {
                    if let url = URL(string: "https://chatgpt.com/settings/usage") { NSWorkspace.shared.open(url) }
                }
                Spacer()
                Button("サインアウト") { Task { await auth.signOut() } }
            }
            .controlSize(.small)
        }
        .onAppear { auth.reloadModels() }
    }
}
