import SwiftUI
import UniformTypeIdentifiers

/// The v0.2 multitrack timeline: fixed-width track headers on the left, a shared
/// horizontally/vertically scrollable canvas of clip lanes on the right.
struct TimelineView: View {
    @EnvironmentObject var project: RemixaProject
    @ObservedObject var engine: TimelineEngine

    @State private var pixelsPerSecond: Double = 60
    @State private var editingClip: (Clip, Track)?

    private let headerWidth: CGFloat = 190
    private let rulerHeight: CGFloat = 26
    private let laneHeight: CGFloat = 88

    private var totalWidth: CGFloat {
        max(800, CGFloat(project.projectDuration + 30) * pixelsPerSecond)
    }

    var body: some View {
        VStack(spacing: 0) {
            timelineToolbar
            Divider()
            HStack(spacing: 0) {
                trackHeaders
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            TimeRulerView(pixelsPerSecond: pixelsPerSecond, bpm: project.bpm, width: totalWidth)
                                .frame(height: rulerHeight)
                            ForEach(project.tracks) { track in
                                TrackLaneView(
                                    track: track,
                                    pixelsPerSecond: pixelsPerSecond,
                                    width: totalWidth,
                                    height: laneHeight,
                                    playhead: engine.currentTime,
                                    onDoubleTapClip: { clip in editingClip = (clip, track) },
                                    onDropAudio: { url, seconds in project.addClip(to: track, audioURL: url, atTimelineStart: seconds) }
                                )
                                .frame(height: laneHeight)
                                Divider()
                            }
                        }
                        playheadLine
                        if let loop = project.loopRegion {
                            loopRegionOverlay(loop)
                        }
                    }
                    .frame(width: totalWidth, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        let seconds = max(0, Double(location.x) / pixelsPerSecond)
                        engine.seek(to: seconds)
                    }
                }
            }
        }
        .sheet(item: Binding(
            get: { editingClip.map { ClipEditingContext(clip: $0.0, track: $0.1) } },
            set: { newValue in editingClip = newValue.map { ($0.clip, $0.track) } }
        )) { context in
            ClipEditorSheet(project: project, clip: context.clip, track: context.track, timelineEngine: engine)
        }
    }

    private var timelineToolbar: some View {
        HStack(spacing: 12) {
            Button {
                let track = project.addTrack()
                _ = track
            } label: {
                Label("トラック追加", systemImage: "plus.rectangle.on.rectangle")
            }
            .fixedSize()

            Divider().frame(height: 16)

            HStack(spacing: 4) {
                Text("BPM").fixedSize()
                TextField("BPM", value: Binding(
                    get: { project.bpm },
                    set: { project.setBPM($0) }
                ), format: .number)
                    .frame(width: 50)
                    .textFieldStyle(.roundedBorder)
            }

            Button {
                project.snapToGrid.toggle()
            } label: {
                Image(systemName: project.snapToGrid ? "square.grid.3x3.fill" : "square.grid.3x3")
            }
            .help("拍グリッドにスナップ")

            Divider().frame(height: 16)

            Button {
                if let (clip, track) = selectedClipAndTrack() {
                    project.splitClip(clip, on: track, at: engine.currentTime)
                }
            } label: { Image(systemName: "scissors") }
            .help("分割")
            .disabled(selectedClipAndTrack() == nil)

            Button {
                if let (clip, track) = selectedClipAndTrack() {
                    project.duplicateClip(clip, on: track)
                }
            } label: { Image(systemName: "plus.square.on.square") }
            .help("複製")
            .disabled(selectedClipAndTrack() == nil)

            Button(role: .destructive) {
                if let (clip, track) = selectedClipAndTrack() {
                    project.deleteClip(clip, on: track)
                }
            } label: { Image(systemName: "trash") }
            .help("クリップ削除")
            .disabled(selectedClipAndTrack() == nil)

            Divider().frame(height: 16)

            Button {
                if let loop = project.loopRegion, abs(loop.lowerBound - engine.currentTime) < 0.01 {
                    project.loopRegion = nil
                } else {
                    let start = engine.currentTime
                    project.loopRegion = start...(start + 4)
                }
            } label: { Image(systemName: "repeat") }
            .help("ループ範囲")

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "minus.magnifyingglass")
                Slider(value: $pixelsPerSecond, in: 15...240)
                Image(systemName: "plus.magnifyingglass")
            }
            .frame(width: 160)
        }
        .padding(8)
        .lineLimit(1)
    }

    private func selectedClipAndTrack() -> (Clip, Track)? {
        guard let id = project.selectedClipID else { return nil }
        for track in project.tracks {
            if let clip = track.clips.first(where: { $0.id == id }) { return (clip, track) }
        }
        return nil
    }

    private var trackHeaders: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: rulerHeight)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(project.tracks) { track in
                        TrackHeaderView(track: track, project: project)
                            .frame(height: laneHeight)
                        Divider()
                    }
                }
            }
        }
        .frame(width: headerWidth)
    }

    private var playheadLine: some View {
        Rectangle()
            .fill(Color.red)
            .frame(width: 1.5)
            .frame(maxHeight: .infinity)
            .offset(x: CGFloat(engine.currentTime) * pixelsPerSecond, y: 0)
    }

    private func loopRegionOverlay(_ loop: ClosedRange<Double>) -> some View {
        Rectangle()
            .fill(Color.orange.opacity(0.15))
            .frame(width: CGFloat(loop.upperBound - loop.lowerBound) * pixelsPerSecond)
            .frame(maxHeight: .infinity)
            .offset(x: CGFloat(loop.lowerBound) * pixelsPerSecond, y: 0)
            .allowsHitTesting(false)
    }
}

private struct ClipEditingContext: Identifiable {
    let clip: Clip
    let track: Track
    var id: UUID { clip.id }
}

private struct TimeRulerView: View {
    let pixelsPerSecond: Double
    let bpm: Double
    let width: CGFloat

    var body: some View {
        Canvas { context, size in
            let beatLength = 60.0 / max(bpm, 1)
            var t = 0.0
            var beatIndex = 0
            while t * pixelsPerSecond < Double(size.width) {
                let x = CGFloat(t * pixelsPerSecond)
                let isBar = beatIndex % 4 == 0
                var path = Path()
                path.move(to: CGPoint(x: x, y: isBar ? 0 : size.height * 0.5))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.secondary.opacity(isBar ? 0.8 : 0.3)))
                if isBar {
                    context.draw(Text(String(format: "%.0fs", t)).font(.caption2), at: CGPoint(x: x + 2, y: 4), anchor: .topLeading)
                }
                t += beatLength
                beatIndex += 1
            }
        }
        .background(Color.gray.opacity(0.08))
    }
}
