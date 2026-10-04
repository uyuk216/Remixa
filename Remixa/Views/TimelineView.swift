import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// The v0.2 multitrack timeline: fixed-width track headers on the left, a shared
/// horizontally/vertically scrollable canvas of clip lanes on the right.
struct TimelineView: View {
    @EnvironmentObject var project: RemixaProject
    @ObservedObject var engine: TimelineEngine

    @State private var pixelsPerSecond: Double = 60
    @State private var editingClip: (Clip, Track)?
    @State private var renamingMarker: ProjectMarker?
    @State private var markerName = ""
    @State private var isAutomationMode = false
    @State private var selectedAutomationParameter: AutomationParameter = .volume
    @StateObject private var horizontalScroller = TimelineHorizontalScroller()

    private let headerWidth: CGFloat = 190
    private let rulerHeight: CGFloat = 26
    private let markerHeight: CGFloat = 25
    private let laneHeight: CGFloat = 88

    var body: some View {
        GeometryReader { geometry in
            let viewportWidth = max(320, geometry.size.width - headerWidth)
            let totalWidth = max(viewportWidth, CGFloat(project.timelineDisplayDuration) * pixelsPerSecond + 24)
            VStack(spacing: 0) {
                timelineToolbar(viewportWidth: viewportWidth)
                Divider()
                HStack(spacing: 0) {
                    trackHeaders
                    Divider()
                    ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) {
                                TimeRulerView(
                                    pixelsPerSecond: pixelsPerSecond,
                                    bpm: project.bpm,
                                    beatsPerBar: project.beatsPerBar,
                                    width: totalWidth
                                )
                                .frame(height: rulerHeight)
                                MarkerRowView(
                                    project: project,
                                    pixelsPerSecond: pixelsPerSecond,
                                    width: totalWidth,
                                    height: markerHeight,
                                    onSelect: { marker in engine.seek(to: marker.time) },
                                    onRename: { marker in
                                        renamingMarker = marker
                                        markerName = marker.name
                                    },
                                    onDelete: { marker in project.deleteMarker(id: marker.id) }
                                )
                                .frame(height: markerHeight)
                                ForEach(project.tracks) { track in
                                    let trackID = track.id
                                    TrackLaneView(
                                        track: track,
                                        pixelsPerSecond: pixelsPerSecond,
                                        width: totalWidth,
                                        height: laneHeight,
                                        playhead: engine.currentTime,
                                        automationParameter: isAutomationMode ? selectedAutomationParameter : nil,
                                        onDoubleTapClip: { clip in editingClip = (clip, track) },
                                        onDropAudio: { url, seconds, isFirst in
                                            guard let destination = project.tracks.first(where: { $0.id == trackID }),
                                                  let clip = project.addClip(
                                                    to: destination,
                                                    audioURL: url,
                                                    atTimelineStart: seconds,
                                                    snapping: isFirst
                                                  ) else { return nil }
                                            return clip.timelineEnd
                                        }
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
                        .background {
                            HorizontalScrollViewLocator(controller: horizontalScroller)
                                .frame(width: 1, height: 1)
                                .opacity(0)
                                .allowsHitTesting(false)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            guard !isAutomationMode else { return }
                            let seconds = max(0, Double(location.x) / pixelsPerSecond)
                            engine.seek(to: seconds)
                        }
                    }
                    .onChange(of: Int(engine.currentTime * pixelsPerSecond / max(180, Double(viewportWidth) * 0.75))) { _, _ in
                        if engine.isPlaying {
                            horizontalScroller.scroll(toX: CGFloat(engine.currentTime) * pixelsPerSecond, anchor: 0.5)
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .remixaZoomIn)) { _ in
                let limits = zoomLimits(viewportWidth: viewportWidth)
                pixelsPerSecond = min(limits.upperBound, pixelsPerSecond * 1.25)
            }
            .onReceive(NotificationCenter.default.publisher(for: .remixaZoomOut)) { _ in
                let limits = zoomLimits(viewportWidth: viewportWidth)
                pixelsPerSecond = max(limits.lowerBound, pixelsPerSecond / 1.25)
            }
            .onReceive(NotificationCenter.default.publisher(for: .remixaFitAll)) { _ in
                fitAll(viewportWidth: viewportWidth)
                horizontalScroller.scroll(toX: 0, anchor: 0)
            }
            .onReceive(NotificationCenter.default.publisher(for: .remixaFitSelection)) { _ in
                fitSelection(viewportWidth: viewportWidth)
            }
            .onReceive(NotificationCenter.default.publisher(for: .remixaScrollToPlayhead)) { _ in
                horizontalScroller.scroll(toX: CGFloat(engine.currentTime) * pixelsPerSecond, anchor: 0.5)
            }
            .onReceive(NotificationCenter.default.publisher(for: .remixaGoToStart)) { _ in
                engine.seek(to: 0)
                horizontalScroller.scroll(toX: 0, anchor: 0)
            }
        }
        .sheet(item: Binding(
            get: { editingClip.map { ClipEditingContext(clip: $0.0, track: $0.1) } },
            set: { newValue in editingClip = newValue.map { ($0.clip, $0.track) } }
        )) { context in
            ClipEditorSheet(project: project, clip: context.clip, track: context.track, timelineEngine: engine)
        }
        .alert("マーカー名を変更", isPresented: Binding(
            get: { renamingMarker != nil },
            set: { if !$0 { renamingMarker = nil } }
        )) {
            TextField("マーカー名", text: $markerName)
            Button("保存") {
                if let marker = renamingMarker { project.updateMarker(id: marker.id, name: markerName) }
                renamingMarker = nil
            }
            Button("キャンセル", role: .cancel) { renamingMarker = nil }
        }
    }

    private func timelineToolbar(viewportWidth: CGFloat) -> some View {
        let limits = zoomLimits(viewportWidth: viewportWidth)
        return HStack(spacing: 12) {
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
                    .help("設定範囲: 20〜400 BPM")
            }

            Menu {
                Toggle("レーンを表示・編集", isOn: $isAutomationMode)
                Picker("表示するパラメータ", selection: $selectedAutomationParameter) {
                    ForEach(AutomationParameter.allCases) { parameter in
                        Text(parameter.japaneseName).tag(parameter)
                    }
                }
            } label: {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .foregroundStyle(isAutomationMode ? Color.accentColor : Color.primary)
            }
            .help("トラックのオートメーション")

            Menu {
                Picker("拍子", selection: Binding(
                    get: { project.timeSignature },
                    set: { project.setTimelineSettings(timeSignature: $0) }
                )) {
                    ForEach(TimeSignature.allCases) { signature in Text(signature.rawValue).tag(signature) }
                }
                Picker("スナップ単位", selection: Binding(
                    get: { project.snapDivision },
                    set: { project.setTimelineSettings(snapDivision: $0) }
                )) {
                    ForEach(SnapDivision.allCases) { division in Text(division.japaneseName).tag(division) }
                }
            } label: {
                Image(systemName: project.snapDivision == .off ? "square.grid.3x3" : "square.grid.3x3.fill")
            }
            .help("拍子・スナップ単位")

            Menu {
                Toggle("再生時のメトロノーム", isOn: Binding(
                    get: { project.playbackMetronomeEnabled },
                    set: { project.setMetronomeSettings(playbackEnabled: $0) }
                ))
                Toggle("再生時に1小節カウントイン", isOn: Binding(
                    get: { project.countInEnabled },
                    set: { project.setMetronomeSettings(countIn: $0) }
                ))
                Divider()
                Toggle("書き出し時のメトロノーム", isOn: Binding(
                    get: { project.exportMetronomeEnabled },
                    set: { project.setMetronomeSettings(exportEnabled: $0) }
                ))
                Slider(value: Binding(
                    get: { project.metronomeVolume },
                    set: { project.setMetronomeSettings(volume: $0) }
                ), in: 0...1, onEditingChanged: { editing in
                    if editing { project.beginUndoCoalescing() } else { project.endUndoCoalescing() }
                })
                Text("クリック音量 \(Int(project.metronomeVolume * 100))%")
            } label: {
                Image(systemName: "metronome")
            }
            .help("メトロノームとカウントイン")

            Button { _ = project.addMarker(at: engine.currentTime) } label: {
                Image(systemName: "mappin.and.ellipse")
            }
            .help("再生位置にマーカーを追加")

            Divider().frame(height: 16)

            Button {
                project.splitSelectedClips(at: engine.currentTime)
            } label: { Image(systemName: "scissors") }
            .help("分割")
            .disabled(project.selectedClipIDs.isEmpty)

            Button {
                project.duplicateSelectedClips()
            } label: { Image(systemName: "plus.square.on.square") }
            .help("複製")
            .disabled(project.selectedClipIDs.isEmpty)

            Button(role: .destructive) {
                project.deleteSelectedClips()
            } label: { Image(systemName: "trash") }
            .help("クリップ削除")
            .disabled(project.selectedClipIDs.isEmpty)

            if let (clip, _) = selectedClipAndTrack() {
                Menu {
                    Picker("プロジェクトのキー", selection: Binding<MusicalKey?>(
                        get: { project.projectKey },
                        set: { project.setProjectKey($0) }
                    )) {
                        Text("未設定").tag(nil as MusicalKey?)
                        ForEach(MusicalKey.all) { key in Text(key.displayName).tag(Optional(key)) }
                    }
                    Button("このクリップのキーを検出") { detectKey(for: clip) }
                    Button("プロジェクトのキーに合わせる") {
                        try? project.matchClipToProjectKey(clipID: clip.id)
                        engine.refreshPlaybackSchedule()
                    }
                    .disabled(project.projectKey == nil || clip.detectedKey == nil)
                    Divider()
                    Button("ピッチを1半音下げる") {
                        project.setClipPitch(clip.pitchSemitones - 1, clipID: clip.id)
                        engine.refreshPlaybackSchedule()
                    }
                    Button("ピッチを1半音上げる") {
                        project.setClipPitch(clip.pitchSemitones + 1, clipID: clip.id)
                        engine.refreshPlaybackSchedule()
                    }
                    Text("現在: \(clip.pitchSemitones) 半音 · キー: \(clip.detectedKey?.displayName ?? "未検出")")
                } label: {
                    Image(systemName: "music.note")
                }
                .help("プロジェクトキー・クリップのピッチ")
            }

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

            Menu {
                Button("全体を表示") { NotificationCenter.default.post(name: .remixaFitAll, object: nil) }
                Button("選択範囲に合わせる") { NotificationCenter.default.post(name: .remixaFitSelection, object: nil) }
                    .disabled(project.selectedClipIDs.isEmpty)
                Button("再生位置へ移動") { NotificationCenter.default.post(name: .remixaScrollToPlayhead, object: nil) }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("タイムラインの表示")

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "minus.magnifyingglass")
                Slider(value: $pixelsPerSecond, in: limits)
                Image(systemName: "plus.magnifyingglass")
            }
            .frame(width: 160)
        }
        .padding(8)
        .lineLimit(1)
    }

    private func fitAll(viewportWidth: CGFloat) {
        let duration = max(1, project.timelineDisplayDuration)
        pixelsPerSecond = Double(max(1, viewportWidth - 24)) / duration
    }

    private func fitSelection(viewportWidth: CGFloat) {
        let selected = project.tracks.flatMap { track in track.clips.filter { project.selectedClipIDs.contains($0.id) } }
        guard let first = selected.min(by: { $0.timelineStart < $1.timelineStart }),
              let last = selected.max(by: { $0.timelineEnd < $1.timelineEnd }) else { return }
        let span = max(0.1, last.timelineEnd - first.timelineStart)
        let limits = zoomLimits(viewportWidth: viewportWidth)
        pixelsPerSecond = min(limits.upperBound, max(limits.lowerBound, Double(max(1, viewportWidth - 24)) / span))
        let targetX = CGFloat(first.timelineStart) * pixelsPerSecond
        Task { @MainActor in
            await Task.yield()
            horizontalScroller.scroll(toX: targetX, anchor: 0)
        }
    }

    private func zoomLimits(viewportWidth: CGFloat) -> ClosedRange<Double> {
        let availableWidth = Double(max(1, viewportWidth - 24))
        let projectSpan = max(1, project.timelineDisplayDuration)
        let allFit = availableWidth / projectSpan
        let selectedClips = project.tracks.flatMap { track in track.clips.filter { project.selectedClipIDs.contains($0.id) } }
        let selectedSpan: Double
        if let first = selectedClips.min(by: { $0.timelineStart < $1.timelineStart }),
           let last = selectedClips.max(by: { $0.timelineEnd < $1.timelineEnd }) {
            selectedSpan = max(0.1, last.timelineEnd - first.timelineStart)
        } else {
            selectedSpan = projectSpan
        }
        let selectionFit = availableWidth / selectedSpan
        return min(0.5, allFit)...max(240, max(allFit, selectionFit) * 4)
    }

    private func detectKey(for clip: Clip) {
        guard let snapshot = project.keyDetectionSnapshot(for: clip.id) else { return }
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                KeyDetector.estimate(
                    fileURL: snapshot.sourceURL,
                    sourceStart: Double(bitPattern: snapshot.sourceStartBits),
                    duration: Double(bitPattern: snapshot.durationBits)
                )
            }.value
            if let result {
                if !project.setDetectedKey(result, matching: snapshot) {
                    project.errorMessage = "解析中に音源またはトリム範囲が変更されたため、結果を破棄しました"
                }
            } else {
                project.errorMessage = "クリップのキーを推定できませんでした"
            }
        }
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
            Color.clear.frame(height: rulerHeight + markerHeight)
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
            .allowsHitTesting(false)
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

@MainActor
private final class TimelineHorizontalScroller: ObservableObject {
    weak var scrollView: NSScrollView?

    func scroll(toX contentX: CGFloat, anchor: CGFloat) {
        guard let scrollView else { return }
        let clipView = scrollView.contentView
        let viewportWidth = clipView.bounds.width
        let documentWidth = scrollView.documentView?.frame.width ?? viewportWidth
        let maximumX = max(0, documentWidth - viewportWidth)
        let originX = min(maximumX, max(0, contentX - viewportWidth * anchor))
        clipView.scroll(to: NSPoint(x: originX, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
    }
}

@MainActor
private struct HorizontalScrollViewLocator: NSViewRepresentable {
    let controller: TimelineHorizontalScroller

    func makeNSView(context: Context) -> TimelineScrollViewLocatorNSView {
        let view = TimelineScrollViewLocatorNSView()
        view.onLocate = { [weak controller] scrollView in
            controller?.scrollView = scrollView
        }
        return view
    }

    func updateNSView(_ nsView: TimelineScrollViewLocatorNSView, context: Context) {
        nsView.locateScrollView()
    }
}

@MainActor
private final class TimelineScrollViewLocatorNSView: NSView {
    var onLocate: (@MainActor (NSScrollView) -> Void)?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        locateScrollView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        locateScrollView()
    }

    func locateScrollView() {
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? NSScrollView {
                onLocate?(scrollView)
                return
            }
            ancestor = view.superview
        }
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
    let beatsPerBar: Int
    let width: CGFloat

    var body: some View {
        Canvas { context, size in
            let beatLength = 60.0 / max(bpm, 1)
            var t = 0.0
            var beatIndex = 0
            while t * pixelsPerSecond < Double(size.width) {
                let x = CGFloat(t * pixelsPerSecond)
                let isBar = beatIndex % max(1, beatsPerBar) == 0
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

private struct MarkerRowView: View {
    @ObservedObject var project: RemixaProject
    let pixelsPerSecond: Double
    let width: CGFloat
    let height: CGFloat
    let onSelect: (ProjectMarker) -> Void
    let onRename: (ProjectMarker) -> Void
    let onDelete: (ProjectMarker) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.orange.opacity(0.05))
            ForEach(project.markers) { marker in
                Button { onSelect(marker) } label: {
                    Label(marker.name, systemImage: "mappin.and.ellipse")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .frame(height: height - 4)
                        .background(Color.orange.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .offset(x: CGFloat(marker.time) * pixelsPerSecond)
                .help("\(marker.name) · \(marker.time, specifier: "%.2f")秒")
                .contextMenu {
                    Button("名前を変更…") { onRename(marker) }
                    Button("この位置へ移動") { onSelect(marker) }
                    Divider()
                    Button("マーカーを削除", role: .destructive) { onDelete(marker) }
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}
