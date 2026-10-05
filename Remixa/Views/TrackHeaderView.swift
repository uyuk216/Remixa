import SwiftUI
import AppKit

enum TrackColorPalette {
    static var items: [(name: String, color: Color)] {
        [
            ("青", Color(nsColor: .systemBlue)),
            ("紫", Color(nsColor: .systemPurple)),
            ("ピンク", Color(nsColor: .systemPink)),
            ("赤", Color(nsColor: .systemRed)),
            ("オレンジ", Color(nsColor: .systemOrange)),
            ("黄", Color(nsColor: .systemYellow)),
            ("緑", Color(nsColor: .systemGreen)),
            ("ティール", Color(nsColor: .systemTeal))
        ]
    }

    static func color(for index: Int) -> Color {
        items[((index % items.count) + items.count) % items.count].color
    }
}

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
                Circle()
                    .fill(TrackColorPalette.color(for: track.colorIndex))
                    .frame(width: 8, height: 8)
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
                    Picker("クリップの色", selection: Binding(
                        get: { track.colorIndex },
                        set: { project.updateTrack(track, colorIndex: $0) }
                    )) {
                        ForEach(0..<Track.colorCount, id: \.self) { index in
                            Label(TrackColorPalette.items[index].name, systemImage: "circle.fill")
                                .foregroundStyle(TrackColorPalette.color(for: index))
                                .tag(index)
                        }
                    }
                    Divider()
                    Button("トラック削除", role: .destructive) { project.deleteTrack(track) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 18)
            }

            HStack(spacing: 6) {
                Toggle("M", isOn: Binding(
                    get: { track.mute },
                    set: { project.updateTrack(track, mute: $0) }
                ))
                    .toggleStyle(.button)
                    .tint(.red)
                Toggle("S", isOn: Binding(
                    get: { track.solo },
                    set: { project.updateTrack(track, solo: $0) }
                ))
                    .toggleStyle(.button)
                    .tint(.yellow)
                Button {
                    showEffects = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .popover(isPresented: $showEffects) {
                    TrackEffectsPopover(track: track, project: project)
                        .frame(width: 320, height: 420)
                }
            }
            .font(.caption)

            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2")
                    .font(.caption2)
                Slider(
                    value: Binding(get: { track.volume }, set: { project.updateTrack(track, volume: $0) }),
                    in: 0...1.5,
                    onEditingChanged: { editing in
                        if editing { project.beginUndoCoalescing() } else { project.endUndoCoalescing() }
                    }
                )
            }
            HStack(spacing: 4) {
                Text("L").font(.caption2)
                Slider(
                    value: Binding(get: { track.pan }, set: { project.updateTrack(track, pan: $0) }),
                    in: -1...1,
                    onEditingChanged: { editing in
                        if editing { project.beginUndoCoalescing() } else { project.endUndoCoalescing() }
                    }
                )
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
    let project: RemixaProject

    var body: some View {
        VStack(alignment: .leading) {
            Text("\(track.name) のエフェクト").font(.headline).padding(.bottom, 4)
            EffectsRackView(effects: Binding(
                get: { track.effects },
                set: { project.updateTrack(track, effects: $0) }
            ), onEditingChanged: { editing in
                if editing { project.beginUndoCoalescing() } else { project.endUndoCoalescing() }
            })
        }
        .padding()
    }
}
