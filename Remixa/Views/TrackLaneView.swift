import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// One horizontal lane on the timeline holding a track's clips.
struct TrackLaneView: View {
    @EnvironmentObject var project: RemixaProject
    @ObservedObject var track: Track
    let pixelsPerSecond: Double
    let width: CGFloat
    let height: CGFloat
    let playhead: Double
    let automationParameter: AutomationParameter?
    let onDoubleTapClip: (Clip) -> Void
    let onDropAudio: @MainActor @Sendable (URL, Double, Bool) -> Double?

    @State private var isDropTargeted = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
            ForEach(track.clips) { clip in
                ClipView(
                    clip: clip,
                    track: track,
                    pixelsPerSecond: pixelsPerSecond,
                    laneHeight: height,
                    isSelected: project.selectedClipIDs.contains(clip.id),
                    playhead: playhead,
                    onDoubleTap: { onDoubleTapClip(clip) }
                )
                .environmentObject(project)
                .allowsHitTesting(automationParameter == nil)
            }
            if let automationParameter {
                AutomationLaneView(
                    track: track,
                    parameter: automationParameter,
                    pixelsPerSecond: pixelsPerSecond,
                    width: width,
                    height: height
                )
                .environmentObject(project)
                .zIndex(1)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers, location in
            handleDrop(providers: providers, at: location)
        }
    }

    @MainActor
    private func handleDrop(providers: [NSItemProvider], at location: CGPoint) -> Bool {
        guard !providers.isEmpty else { return false }
        let timelineStart = max(0, Double(location.x) / pixelsPerSecond)
        AudioDropSequence(providers: providers, timelineStart: timelineStart, onDropAudio: onDropAudio).start()
        return true
    }
}

@MainActor
private final class AudioDropSequence {
    private let providers: [NSItemProvider]
    private let onDropAudio: @MainActor @Sendable (URL, Double, Bool) -> Double?
    private var timelineStart: Double
    private var nextProviderIndex = 0
    private var didPlaceClip = false

    init(
        providers: [NSItemProvider],
        timelineStart: Double,
        onDropAudio: @escaping @MainActor @Sendable (URL, Double, Bool) -> Double?
    ) {
        self.providers = providers
        self.timelineStart = timelineStart
        self.onDropAudio = onDropAudio
    }

    func start() {
        loadNextProvider()
    }

    private func loadNextProvider() {
        guard nextProviderIndex < providers.count else { return }
        let provider = providers[nextProviderIndex]
        nextProviderIndex += 1
        _ = provider.loadObject(ofClass: URL.self) { [self] url, _ in
            Task { @MainActor [self] in
                if let url,
                   let nextStart = onDropAudio(url, timelineStart, !didPlaceClip) {
                    timelineStart = nextStart
                    didPlaceClip = true
                }
                loadNextProvider()
            }
        }
    }
}

/// A single clip block: drag to move, drag edge handles to trim, double-click to
/// open in the v0.1 single-file editor.
private struct ClipView: View {
    @EnvironmentObject var project: RemixaProject
    let clip: Clip
    @ObservedObject var track: Track
    let pixelsPerSecond: Double
    let laneHeight: CGFloat
    let isSelected: Bool
    let playhead: Double
    let onDoubleTap: () -> Void

    @State private var dragOffsetSeconds: Double = 0
    @State private var isDraggingBody = false

    private let handleWidth: CGFloat = 7

    private var clipWidth: CGFloat { max(10, CGFloat(clip.timelineDuration) * pixelsPerSecond) }
    private var clipX: CGFloat {
        let sharedDelta = project.selectedClipIDs.contains(clip.id) ? project.previewMoveDelta : 0
        return CGFloat(clip.timelineStart + sharedDelta + dragOffsetSeconds) * pixelsPerSecond
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(TrackColorPalette.color(for: track.colorIndex).opacity(isSelected ? 0.76 : 0.56))
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text(clip.name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    if !changeBadge.isEmpty {
                        Text(changeBadge)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.black.opacity(0.4), in: Capsule())
                    }
                }
                .padding(.horizontal, 5)
                .frame(height: 21)
                .background(Color.black.opacity(0.5))

                Canvas { context, size in
                    let path = waveformPath(in: size)
                    context.stroke(path, with: .color(.primary.opacity(0.9)), lineWidth: 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))

            HStack(spacing: 0) {
                trimHandle(leading: true)
                Spacer()
                trimHandle(leading: false)
            }

            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(
                    isSelected ? Color.accentColor : TrackColorPalette.color(for: track.colorIndex).opacity(0.95),
                    lineWidth: isSelected ? 2.5 : 1
                )
                .shadow(color: isSelected ? Color.accentColor.opacity(0.35) : .clear, radius: 3)
        }
        .frame(width: clipWidth, height: laneHeight - 12)
        .offset(x: clipX, y: 6)
        .id(clip.id)
        .onTapGesture(count: 2) { onDoubleTap() }
        .onTapGesture(count: 1) {
            project.selectClip(
                clip.id,
                command: NSEvent.modifierFlags.contains(.command),
                shift: NSEvent.modifierFlags.contains(.shift)
            )
        }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    isDraggingBody = true
                    if !project.selectedClipIDs.contains(clip.id) { project.selectClip(clip.id) }
                    project.setPreviewMoveDelta(Double(value.translation.width) / pixelsPerSecond)
                }
                .onEnded { value in
                    let delta = Double(value.translation.width) / pixelsPerSecond
                    dragOffsetSeconds = 0
                    isDraggingBody = false
                    project.moveSelectedClips(by: delta)
                }
        )
        .contextMenu { clipMenu }
    }

    @ViewBuilder
    private var clipMenu: some View {
        Button("分割") { project.splitClip(clip, on: track, at: playhead) }
        Button("複製") { project.duplicateClip(clip, on: track) }
        Button("削除", role: .destructive) { project.deleteClip(clip, on: track) }
        Divider()
        Button("パート分離") {
            NotificationCenter.default.post(name: .remixaSeparateStems, object: nil, userInfo: ["clipId": clip.id])
        }
        Button("BPMに合わせる") { run { try project.syncClipTempo(clipId: clip.id) } }
        Button("キーを合わせる") { run { try project.matchClipToProjectKey(clipID: clip.id) } }
        Divider()
        Button("インスペクタで開く") {
            project.selectClip(clip.id)
            NotificationCenter.default.post(name: .remixaToggleInspector, object: nil)
        }
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { project.errorMessage = error.localizedDescription }
    }

    private var changeBadge: String {
        var parts: [String] = []
        if abs(clip.tempoRate - 1) > 0.001 { parts.append(String(format: "%.2f×", clip.tempoRate)) }
        if let sourceBPM = clip.sourceBPM { parts.append(String(format: "%.0f BPM", sourceBPM)) }
        if clip.syncToProject { parts.append("同期") }
        if clip.pitchSemitones != 0 { parts.append("\(clip.pitchSemitones > 0 ? "+" : "")\(clip.pitchSemitones)半音") }
        if let key = clip.detectedKey { parts.append(key.name) }
        return parts.joined(separator: " · ")
    }

    /// Builds the waveform stroke path for the visible (trimmed) portion of the clip,
    /// sliced out of the whole-source-file peaks cached per file in `project`.
    private func waveformPath(in size: CGSize) -> Path {
        guard let waveform = project.waveform(for: clip),
              waveform.sourceDuration > 0,
              !waveform.peaks.isEmpty else { return Path() }

        let peakCount = waveform.peaks.count
        let startFraction = clip.sourceStart / waveform.sourceDuration
        let endFraction = (clip.sourceStart + clip.duration) / waveform.sourceDuration
        let startIndex = max(0, min(peakCount - 1, Int(startFraction * Double(peakCount))))
        let endIndex = max(startIndex + 1, min(peakCount, Int(endFraction * Double(peakCount))))
        let slice = waveform.peaks[startIndex..<endIndex]
        guard !slice.isEmpty else { return Path() }

        let midY = size.height / 2
        let stepX = size.width / CGFloat(slice.count)
        let gain = Float(clip.gain)
        var path = Path()
        for (i, peak) in slice.enumerated() {
            let x = CGFloat(i) * stepX
            let h = CGFloat(min(1, peak * gain)) * midY
            path.move(to: CGPoint(x: x, y: midY - h))
            path.addLine(to: CGPoint(x: x, y: midY + h))
        }
        return path
    }

    private func trimHandle(leading: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001)) // invisible but hit-testable
            .frame(width: handleWidth)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        applyTrim(leading: leading, translation: Double(value.translation.width))
                    }
                    .onEnded { value in
                        applyTrim(leading: leading, translation: Double(value.translation.width), commit: true)
                    }
            )
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.set() }
            }
    }

    private func applyTrim(leading: Bool, translation: Double, commit: Bool = false) {
        let deltaSeconds = translation / pixelsPerSecond
        let sourceDelta = deltaSeconds * clip.tempoRate
        if leading {
            let newStart = max(0, clip.timelineStart + deltaSeconds)
            let newSourceStart = max(0, clip.sourceStart + (newStart - clip.timelineStart) * clip.tempoRate)
            let newDuration = clip.duration - (newStart - clip.timelineStart) * clip.tempoRate
            if commit, newDuration > 0.05 {
                project.trimClip(clip, on: track, newStart: newStart, newDuration: newDuration, newSourceStart: newSourceStart)
            }
        } else {
            let newDuration = max(0.05, clip.duration + sourceDelta)
            if commit {
                project.trimClip(clip, on: track, newStart: clip.timelineStart, newDuration: newDuration, newSourceStart: clip.sourceStart)
            }
        }
    }
}
