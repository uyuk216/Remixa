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
    private let rulerHeight: CGFloat = 34
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
                                    snapDivision: project.snapDivision,
                                    markers: project.markers,
                                    onSeek: { engine.seek(to: $0) },
                                    onLoopChange: { project.loopRegion = $0 }
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
                    }
                    .overlay { emptyGuide }
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

    /// Guide card centered in the track area, below the ruler and marker row.
    @ViewBuilder
    private var emptyGuide: some View {
        if project.tracks.allSatisfy({ $0.clips.isEmpty }) {
            VStack(spacing: 0) {
                Color.clear.frame(height: rulerHeight + markerHeight)
                emptyGuideCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var emptyGuideCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("ミックスを始めましょう")
                .font(.headline)
            Text("ここに音声ファイルをドロップ")
                .foregroundStyle(.secondary)
            Button {
                NotificationCenter.default.post(name: .remixaAddAudioTrack, object: nil)
            } label: {
                Label("ファイルを追加…", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }

    @ViewBuilder
    private func timelineToolbar(viewportWidth: CGFloat) -> some View {
        let limits = zoomLimits(viewportWidth: viewportWidth)
        ViewThatFits(in: .horizontal) {
            toolbarContent(compact: false, limits: limits)
            toolbarContent(compact: true, limits: limits)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func toolbarContent(compact: Bool, limits: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Button {
                _ = project.addTrack()
            } label: {
                controlLabel("トラック追加", "plus.rectangle.on.rectangle", compact: compact)
            }
            .help("トラック追加")

            Menu {
                Toggle("レーンを表示・編集", isOn: $isAutomationMode)
                Picker("表示するパラメータ", selection: $selectedAutomationParameter) {
                    ForEach(AutomationParameter.allCases) { parameter in
                        Text(parameter.japaneseName).tag(parameter)
                    }
                }
            } label: {
                controlLabel("オートメーション", "point.topleft.down.curvedto.point.bottomright.up", compact: compact)
                    .foregroundStyle(isAutomationMode ? Color.accentColor : Color.primary)
            }
            .help("オートメーションレーン")

            Menu {
                Toggle("再生時に1小節カウントイン", isOn: Binding(
                    get: { project.countInEnabled },
                    set: { project.setMetronomeSettings(countIn: $0) }
                ))
                Toggle("書き出しにクリック音を含める", isOn: Binding(
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
                controlLabel("クリック設定", "metronome", compact: compact)
            }
            .help("カウントインと書き出し時のクリック設定")

            Button { _ = project.addMarker(at: engine.currentTime) } label: {
                controlLabel("マーカー", "mappin.and.ellipse", compact: compact)
            }
            .help("再生位置にマーカーを追加")

            Menu {
                Button("分割") { project.splitSelectedClips(at: engine.currentTime) }
                    .keyboardShortcut("b", modifiers: [.command])
                    .disabled(project.selectedClipIDs.isEmpty)
                Button("複製") { project.duplicateSelectedClips() }
                    .keyboardShortcut("d", modifiers: [.command])
                    .disabled(project.selectedClipIDs.isEmpty)
                Button("削除") { project.deleteSelectedClips() }
                    .keyboardShortcut(.delete)
                    .disabled(project.selectedClipIDs.isEmpty)
            } label: {
                controlLabel("編集", "scissors", compact: compact)
            }
            .help("編集: 分割・複製・削除")

            Menu {
                Picker("スナップ", selection: Binding(
                    get: { project.snapDivision },
                    set: { project.setTimelineSettings(snapDivision: $0) }
                )) {
                    ForEach(SnapDivision.allCases) { division in
                        Text(division.japaneseName).tag(division)
                    }
                }
                Divider()
                HStack {
                    Image(systemName: "minus.magnifyingglass")
                    Slider(value: $pixelsPerSecond, in: limits)
                    Image(systemName: "plus.magnifyingglass")
                }
                .frame(width: 180)
                Button("全体を表示") { NotificationCenter.default.post(name: .remixaFitAll, object: nil) }
                Button("選択範囲に合わせる") { NotificationCenter.default.post(name: .remixaFitSelection, object: nil) }
                    .disabled(project.selectedClipIDs.isEmpty)
                Button("再生位置へ移動") { NotificationCenter.default.post(name: .remixaScrollToPlayhead, object: nil) }
            } label: {
                controlLabel("表示", "arrow.up.left.and.arrow.down.right", compact: compact)
            }
            .help("表示: スナップ・ズーム・全体表示")
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func controlLabel(_ title: String, _ symbol: String, compact: Bool) -> some View {
        if compact {
            Image(systemName: symbol)
        } else {
            Label(title, systemImage: symbol).lineLimit(1).fixedSize()
        }
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
    let snapDivision: SnapDivision
    let markers: [ProjectMarker]
    let onSeek: (Double) -> Void
    let onLoopChange: (ClosedRange<Double>) -> Void

    @State private var dragStartX: CGFloat?
    @State private var isLoopDrag = false

    var body: some View {
        Canvas { context, size in
            let beatLength = 60.0 / max(bpm, 1)
            let barSpacing = beatLength * Double(max(1, beatsPerBar)) * pixelsPerSecond
            let barLabelStep = max(1, niceIntegerStep(for: 42 / max(barSpacing, 0.001)))
            var t = 0.0
            var beatIndex = 0
            while t * pixelsPerSecond < Double(size.width) {
                let x = CGFloat(t * pixelsPerSecond)
                let isBar = beatIndex % max(1, beatsPerBar) == 0
                var path = Path()
                path.move(to: CGPoint(x: x, y: isBar ? 0 : size.height * 0.56))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.primary.opacity(isBar ? 0.35 : 0.13)))
                let barNumber = beatIndex / max(1, beatsPerBar) + 1
                if isBar && (barNumber - 1) % barLabelStep == 0 {
                    context.draw(
                        Text("\(barNumber)")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.primary),
                        at: CGPoint(x: x + 3, y: 1),
                        anchor: .topLeading
                    )
                }
                t += beatLength
                beatIndex += 1
            }

            let secondLabelStep = secondLabelStep()
            var second = 0.0
            while second * pixelsPerSecond < Double(size.width) {
                let x = CGFloat(second * pixelsPerSecond)
                let minute = Int(second) / 60
                let remainder = Int(second) % 60
                context.draw(
                    Text(String(format: "%d:%02d", minute, remainder))
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary),
                    at: CGPoint(x: x + 3, y: size.height - 11),
                    anchor: .topLeading
                )
                second += secondLabelStep
            }

            for marker in markers {
                let x = CGFloat(marker.time) * pixelsPerSecond
                guard x < size.width else { continue }
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.orange.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                context.fill(Path(ellipseIn: CGRect(x: x - 3, y: 1, width: 6, height: 6)), with: .color(.orange))
            }
        }
        .background(Color.primary.opacity(0.035))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartX == nil { dragStartX = value.startLocation.x }
                    guard let dragStartX else { return }
                    if abs(value.location.x - dragStartX) > 4 { isLoopDrag = true }
                    guard isLoopDrag else { return }
                    let start = snappedTime(for: min(dragStartX, value.location.x))
                    let end = snappedTime(for: max(dragStartX, value.location.x))
                    onLoopChange(start...max(start + 0.05, end))
                }
                .onEnded { value in
                    guard let dragStartX else { return }
                    if isLoopDrag {
                        let start = snappedTime(for: min(dragStartX, value.location.x))
                        let end = snappedTime(for: max(dragStartX, value.location.x))
                        onLoopChange(start...max(start + 0.05, end))
                    } else {
                        onSeek(max(0, Double(value.location.x) / pixelsPerSecond))
                    }
                    self.dragStartX = nil
                    isLoopDrag = false
                }
        )
        .help("クリックで再生位置を移動、ドラッグでループ範囲を設定")
    }

    private func snappedTime(for x: CGFloat) -> Double {
        let seconds = max(0, Double(x) / pixelsPerSecond)
        let beatLength = 60.0 / max(1, bpm)
        let interval: Double
        switch snapDivision {
        case .quarterBeat: interval = beatLength / 4
        case .halfBeat: interval = beatLength / 2
        case .beat: interval = beatLength
        case .bar: interval = beatLength * Double(max(1, beatsPerBar))
        case .off: return seconds
        }
        return (seconds / interval).rounded() * interval
    }

    private func niceIntegerStep(for minimum: Double) -> Int {
        let target = max(1, Int(ceil(minimum)))
        let magnitude = pow(10, floor(log10(Double(target))))
        let normalized = Double(target) / magnitude
        let factor: Double = normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10
        return max(1, Int(factor * magnitude))
    }

    /// Smallest step (seconds) that keeps labels at least 60pt apart.
    private func secondLabelStep() -> Double {
        let candidates: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        let minimum = 60 / max(pixelsPerSecond, 0.001)
        return candidates.first(where: { $0 >= minimum }) ?? 3600
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
