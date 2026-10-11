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
            Text("ChatGPTプランを使う").font(.headline)
            Text("対象のAIリクエストを、お使いのChatGPTプランまたはクレジットの範囲で実行します。Remixaの利用料とは別です(Remixaは無料)。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("お使いのChatGPTプラン(Plus/Pro)でAIアシスタントを使えます")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ContinueWithChatGPTButton { auth.signIn() }
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
            if !auth.models.isEmpty { ChatGPTModelPickers(auth: auth) }
            if auth.planAvailable { ChatGPTPlanIndicator() }
            HStack {
                Spacer()
                Button("サインアウト") { Task { await auth.signOut() } }
            }
            .controlSize(.small)
        }
        .onAppear { auth.reloadModels() }
    }
}

private struct ChatGPTModelPickers: View {
    @ObservedObject var auth: ChatGPTAuth

    private var modelBinding: Binding<String> {
        Binding(get: { auth.selectedModel ?? "" }, set: { auth.selectModel($0) })
    }

    private var effortBinding: Binding<String> {
        Binding(get: { auth.reasoningEffort ?? "" }, set: { auth.selectReasoningEffort($0.isEmpty ? nil : $0) })
    }

    private var efforts: [String] {
        auth.models.first(where: { $0.slug == auth.selectedModel })?.selectableEfforts ?? ChatGPTModel.baseEfforts
    }

    var body: some View {
        HStack {
            Picker("モデル", selection: modelBinding) {
                ForEach(auth.models) { model in
                    Text(model.displayName).tag(model.slug)
                }
            }
            if !efforts.isEmpty {
                Picker("思考量", selection: effortBinding) {
                    Text("自動").tag("")
                    ForEach(efforts, id: \.self) { effort in
                        Text(ChatGPTModel.effortLabel(effort)).tag(effort)
                    }
                }
            }
        }
        .font(.caption)
    }
}
