import SwiftUI

/// Spinner + status line + elapsed seconds + cancel, shown above the input while a run is active.
struct AIProgressStrip: View {
    @ObservedObject var runner: AIAssistantRunner

    var body: some View {
        if runner.isRunning {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                Text(runner.statusText ?? "考え中…")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                ElapsedSeconds(since: runner.startedAt)
                Spacer()
                Button("キャンセル") { runner.cancel() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

private struct ElapsedSeconds: View {
    let since: Date?

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = since.map { max(0, Int(context.date.timeIntervalSince($0))) } ?? 0
            Text("\(seconds)秒")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
