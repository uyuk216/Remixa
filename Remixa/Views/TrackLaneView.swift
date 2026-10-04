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
    let onDoubleTapClip: (Clip) -> Void
    let onDropAudio: @MainActor @Sendable (URL, Double) -> Void

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
                    onDoubleTap: { onDoubleTapClip(clip) }
                )
                .environmentObject(project)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers, location in
            handleDrop(providers: providers, at: location)
        }
    }

    private func handleDrop(providers: [NSItemProvider], at location: CGPoint) -> Bool {
        guard !providers.isEmpty else { return false }
        let timelineStart = max(0, Double(location.x) / pixelsPerSecond)
        let dropHandler = onDropAudio
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    dropHandler(url, timelineStart)
                }
            }
        }
        return true
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
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(isSelected ? 0.85 : 0.55))
            Canvas { context, size in
                let path = waveformPath(in: size)
                context.stroke(path, with: .color(.white.opacity(0.8)), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.white : Color.clear, lineWidth: 1.5)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                Text(tempoSummary)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                Spacer()
            }
            HStack(spacing: 0) {
                trimHandle(leading: true)
                Spacer()
                trimHandle(leading: false)
            }
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
        .contextMenu {
            Button("テンポ/BPMを編集…") { onDoubleTap() }
            Menu("音源内容をナッジ") {
                Button("前へ 10 ms") { project.nudgeClipContent(clip, on: track, by: -0.01) }
                Button("後ろへ 10 ms") { project.nudgeClipContent(clip, on: track, by: 0.01) }
                Divider()
                Button("前へ 1 拍") { project.nudgeClipContent(clip, on: track, by: -60.0 / max(project.bpm, 1)) }
                Button("後ろへ 1 拍") { project.nudgeClipContent(clip, on: track, by: 60.0 / max(project.bpm, 1)) }
            }
            Divider()
            Button("複製") {
                if !project.selectedClipIDs.contains(clip.id) { project.selectClip(clip.id) }
                project.duplicateSelectedClips()
            }
            Button("パート分離…") {
                NotificationCenter.default.post(name: .remixaSeparateStems, object: nil, userInfo: ["clipId": clip.id])
            }
            Button("削除", role: .destructive) {
                if !project.selectedClipIDs.contains(clip.id) { project.selectClip(clip.id) }
                project.deleteSelectedClips()
            }
        }
    }

    private var tempoSummary: String {
        let rate = String(format: "%.2f×", clip.tempoRate)
        let bpm = clip.sourceBPM.map { String(format: "%.0f BPM", $0) } ?? "元BPM未設定"
        let pitch = clip.pitchSemitones == 0 ? "±0半音" : "\(clip.pitchSemitones > 0 ? "+" : "")\(clip.pitchSemitones)半音"
        let key = clip.detectedKey.map { " · \($0.name)" } ?? ""
        return "\(rate) · \(bpm)\(clip.syncToProject ? " · 同期" : "") · \(pitch)\(key)"
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
