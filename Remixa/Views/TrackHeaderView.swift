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
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            nameRow

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
        .contentShape(Rectangle())
        .contextMenu { trackMenuItems }
        .dropDestination(for: String.self) { ids, _ in handleDrop(ids) }
    }

    private var nameRow: some View {
        HStack {
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("ドラッグでトラックの順番を入れ替え")
                .draggable(track.id.uuidString)
            Circle()
                .fill(TrackColorPalette.color(for: track.colorIndex))
                .frame(width: 8, height: 8)
            nameField
            Spacer()
            Menu {
                trackMenuItems
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 18)
        }
    }

    @ViewBuilder
    private var nameField: some View {
        if isRenaming {
            TextField("トラック名", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .focused($nameFocused)
                .onSubmit { commitRename() }
                .onExitCommand { isRenaming = false }
                .onChange(of: nameFocused) { _, focused in
                    if !focused && isRenaming { commitRename() }
                }
        } else {
            Text(track.name)
                .font(.callout.bold())
                .lineLimit(1)
                .onTapGesture(count: 2) { beginRename() }
        }
    }

    private func beginRename() {
        draftName = track.name
        isRenaming = true
        nameFocused = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != track.name {
            project.rename(track, to: trimmed)
        }
    }

    @ViewBuilder
    private var trackMenuItems: some View {
        Button("名前を変更") { beginRename() }
        Picker("色", selection: Binding(
            get: { track.colorIndex },
            set: { project.updateTrack(track, colorIndex: $0) }
        )) {
            ForEach(0..<Track.colorCount, id: \.self) { index in
                Label(TrackColorPalette.items[index].name, systemImage: "circle.fill")
                    .foregroundStyle(TrackColorPalette.color(for: index))
                    .tag(index)
            }
        }
        Button("複製") { project.duplicateTrack(track) }
        Button("削除", role: .destructive) { project.deleteTrack(track) }
        Divider()
        Button("上へ移動") { project.moveTrack(track, by: -1) }
            .disabled(project.tracks.first?.id == track.id)
        Button("下へ移動") { project.moveTrack(track, by: 1) }
            .disabled(project.tracks.last?.id == track.id)
    }

    private func handleDrop(_ ids: [String]) -> Bool {
        guard let raw = ids.first, let id = UUID(uuidString: raw),
              let source = project.tracks.first(where: { $0.id == id }),
              source.id != track.id else { return false }
        project.moveTrack(source, onto: track)
        return true
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
