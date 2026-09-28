import SwiftUI

struct TransportView: View {
    @EnvironmentObject var document: AudioDocument
    @ObservedObject var engine: AudioEngineController

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                Button {
                    engine.togglePlayPause()
                } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                }
                .keyboardShortcut(.space, modifiers: [])

                Button {
                    engine.stop()
                } label: {
                    Image(systemName: "stop.fill")
                }

                Toggle("ループ", isOn: $document.loopEnabled)
                    .toggleStyle(.button)

                Text(timeString(engine.currentTime) + " / " + timeString(document.duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Spacer()

                Button("トリム") { document.trimToSelection() }
                    .disabled(document.selection == nil)
                Button("削除") { document.deleteSelection() }
                    .disabled(document.selection == nil)
                Button("フェードイン") { document.fadeSelection(fadeIn: true) }
                    .disabled(document.selection == nil)
                Button("フェードアウト") { document.fadeSelection(fadeIn: false) }
                    .disabled(document.selection == nil)

                Button {
                    document.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!document.canUndo)
                Button {
                    document.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!document.canRedo)
            }

            HStack {
                Text("テンポ \(Int(document.tempoPercent))%")
                    .frame(width: 110, alignment: .leading)
                Slider(value: $document.tempoPercent, in: 50...200, step: 1)
            }
            HStack {
                Text("ピッチ \(document.pitchSemitones >= 0 ? "+" : "")\(Int(document.pitchSemitones))st")
                    .frame(width: 110, alignment: .leading)
                Slider(value: $document.pitchSemitones, in: -12...12, step: 1)
            }
        }
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
