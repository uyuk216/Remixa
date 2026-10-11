import SwiftUI

/// OpenAI-approved ChatGPT logo variants (vector assets; automatically switch for dark appearance).
enum ChatGPTLogo {
    case button, dialog, usage, card

    var assetName: String {
        switch self {
        case .button: return "ChatGPTLogoButton"
        case .dialog: return "ChatGPTLogoDialog"
        case .usage: return "ChatGPTLogoUsage"
        case .card: return "ChatGPTLogoCard"
        }
    }

    var size: CGFloat {
        switch self {
        case .button: return 21
        case .dialog: return 72
        case .usage: return 20
        case .card: return 24
        }
    }
}

struct ChatGPTLogoView: View {
    let logo: ChatGPTLogo

    var body: some View {
        Image(logo.assetName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: logo.size, height: logo.size)
            .accessibilityHidden(true)
    }
}

enum ChatGPTLinks {
    static let usage = URL(string: "https://chatgpt.com/settings/usage")!
}

/// Official "Continue with ChatGPT" button: 45pt high, 12pt radius, 20pt padding, 12pt gap, 15pt/500 label.
struct ContinueWithChatGPTButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ContinueWithChatGPTLabel()
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .frame(maxWidth: 242)
    }
}

private struct ContinueWithChatGPTLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isFocused) private var isFocused

    private var background: Color { colorScheme == .dark ? .white : .black }
    private var foreground: Color { colorScheme == .dark ? .black : .white }

    var body: some View {
        HStack(spacing: 12) {
            ChatGPTLogoView(logo: .button)
            Text("Continue with ChatGPT")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(foreground)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 45, maxHeight: 45)
        .background(background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .inset(by: -3)
                .stroke(Color(red: 0x23 / 255, green: 0x66 / 255, blue: 0xd1 / 255), lineWidth: 3)
                .opacity(isFocused ? 1 : 0)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .focusable()
    }
}

/// "Using ChatGPT plan" indicator with a Manage usage link, shown near the model selector.
struct ChatGPTPlanIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            ChatGPTLogoView(logo: .usage)
            Text("ChatGPTプランを使用中")
                .font(.caption)
            Spacer()
            Link("使用量を管理", destination: ChatGPTLinks.usage)
                .font(.caption)
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Compact usage-limit card (ChatGPT identity header, primary "Manage usage" action).
struct ChatGPTUsageLimitCard: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ChatGPTLogoView(logo: .card)
                Text("ChatGPT").font(.subheadline.weight(.semibold))
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("閉じる")
            }
            Text("利用上限に達しました").font(.headline)
            Text("ChatGPTプラン、またはこのアプリの上限に達しています。ChatGPTの設定で上限を確認してください。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("使用量を管理") { NSWorkspace.shared.open(ChatGPTLinks.usage) }
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Shown once, after the first sign-in with ChatGPT plan usage enabled.
struct ChatGPTWelcomeView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ChatGPTLogoView(logo: .dialog)
            Text("ChatGPTプランを使用中です").font(.title3.weight(.semibold))
            Text("このアプリの対象のAIリクエストは、お使いのChatGPTプランを使用します。使用量はChatGPTの設定で管理できます。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("OK", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(28)
        .frame(width: 340)
    }
}
