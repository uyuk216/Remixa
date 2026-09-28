import SwiftUI

/// Left-hand mixer strip for one track: name, volume/pan, mute/solo, effects rack access.
struct TrackHeaderView: View {
    @ObservedObject var track: Track
    let project: RemixaProject

    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var showEffects = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if isRenaming {
                    TextField("トラック名", text: $draftName, onCommit: {
                        project.rename(track, to: draftName.isEmpty ? track.name : draftName)
                        isRenaming = false
                    })
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                } else {
                    Text(track.name)
                        .font(.callout.bold())
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            draftName = track.name
                            isRenaming = true
                        }
                }
                Spacer()
                Menu {
                    Button("トラック削除", role: .destructive) { project.deleteTrack(track) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 18)
            }

            HStack(spacing: 6) {
                Toggle("M", isOn: $track.mute)
                    .toggleStyle(.button)
                    .tint(.red)
                Toggle("S", isOn: $track.solo)
                    .toggleStyle(.button)
                    .tint(.yellow)
                Button {
                    showEffects = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .popover(isPresented: $showEffects) {
                    TrackEffectsPopover(track: track)
                        .frame(width: 320, height: 420)
                }
            }
            .font(.caption)

            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2")
                    .font(.caption2)
                Slider(value: $track.volume, in: 0...1.5)
            }
            HStack(spacing: 4) {
                Text("L").font(.caption2)
                Slider(value: $track.pan, in: -1...1)
                Text("R").font(.caption2)
            }
        }
        .padding(8)
    }
}

/// Wraps the existing v0.1 `EffectsRackView` so it can operate on a track's own
/// `EffectsRackSettings` instead of the single-clip `AudioDocument`'s.
private struct TrackEffectsPopover: View {
    @ObservedObject var track: Track

    var body: some View {
        VStack(alignment: .leading) {
            Text("\(track.name) のエフェクト").font(.headline).padding(.bottom, 4)
            EffectsRackView(effects: Binding(
                get: { track.effects },
                set: { track.effects = $0 }
            ))
        }
        .padding()
    }
}
