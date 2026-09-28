import AVFoundation
import Combine

/// Drives synchronized playback of the whole multitrack arrangement: one
/// `AVAudioPlayerNode` + `EffectsGraph` + mixer per track, summed into the engine's
/// main mixer. Uses host-time-based scheduling so all tracks stay in sample-accurate
/// sync regardless of how many clips each one has.
@MainActor
final class TimelineEngine: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0

    private let engine = AVAudioEngine()
    private var perTrack: [UUID: TrackNodes] = [:]
    private weak var project: RemixaProject?
    private var displayTimer: Timer?

    private var playbackAnchorWallTime: TimeInterval = 0
    private var playbackAnchorPosition: Double = 0
    private var didStartEngine = false

    private struct TrackNodes {
        let player = AVAudioPlayerNode()
        let graph = EffectsGraph()
        let mixer = AVAudioMixerNode()
    }

    nonisolated static let projectFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

    func attach(project: RemixaProject) {
        self.project = project
        rebuildGraph()
    }

    /// Rebuild the node graph to match `project.tracks` (call after add/remove track).
    func rebuildGraph() {
        guard let project else { return }
        let wasPlaying = isPlaying
        if wasPlaying { stop() }

        for nodes in perTrack.values {
            engine.disconnectNodeOutput(nodes.player)
            engine.detach(nodes.player)
            nodes.graph.orderedNodes.forEach { engine.detach($0) }
            engine.detach(nodes.mixer)
        }
        perTrack.removeAll()

        for track in project.tracks {
            let nodes = TrackNodes()
            engine.attach(nodes.player)
            nodes.graph.attach(to: engine)
            engine.attach(nodes.mixer)
            nodes.graph.connectChain(in: engine, from: nodes.player, to: nodes.mixer, format: Self.projectFormat)
            engine.connect(nodes.mixer, to: engine.mainMixerNode, format: Self.projectFormat)
            perTrack[track.id] = nodes
        }
        syncMixState()
    }

    /// Pushes volume/pan/mute/solo/effects from the model onto the live nodes.
    /// Cheap enough to call on every relevant `@Published` change.
    func syncMixState() {
        guard let project else { return }
        engine.mainMixerNode.outputVolume = Float(project.masterVolume)
        let anySolo = project.anySolo
        for track in project.tracks {
            guard let nodes = perTrack[track.id] else { continue }
            let audible = track.solo || (!anySolo && !track.mute)
            nodes.mixer.outputVolume = audible ? Float(track.volume) : 0
            nodes.mixer.pan = Float(track.pan)
            nodes.graph.apply(track.effects, tempoPercent: 100, pitchSemitones: 0)
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let project else { return }
        if !didStartEngine {
            engine.prepare()
            try? engine.start()
            didStartEngine = true
        }
        if !engine.isRunning { try? engine.start() }
        syncMixState()

        let startTime = currentTime
        let startHost = mach_absolute_time() &+ AVAudioTime.hostTime(forSeconds: 0.08)

        for track in project.tracks {
            guard let nodes = perTrack[track.id] else { continue }
            nodes.player.stop()
            for clip in track.clips where clip.timelineEnd > startTime {
                guard let sourceBuffer = project.buffer(for: clip),
                      let processed = TimelineEngine.processedBuffer(for: clip, source: sourceBuffer) else { continue }
                let clipInnerOffset = max(0, startTime - clip.timelineStart)
                let framesPerSecond = processed.format.sampleRate
                let sliceStart = AVAudioFramePosition(clipInnerOffset * framesPerSecond)
                guard let slice = processed.slice(from: sliceStart, to: AVAudioFramePosition(processed.frameLength)) else { continue }
                let scheduleDelay = max(0, clip.timelineStart - startTime)
                let atHost = startHost &+ AVAudioTime.hostTime(forSeconds: scheduleDelay)
                nodes.player.scheduleBuffer(slice, at: AVAudioTime(hostTime: atHost), options: [], completionHandler: nil)
            }
            nodes.player.play()
        }

        playbackAnchorWallTime = ProcessInfo.processInfo.systemUptime + 0.08
        playbackAnchorPosition = startTime
        isPlaying = true
        startDisplayTimer()
    }

    func pause() {
        for nodes in perTrack.values { nodes.player.pause() }
        isPlaying = false
        stopDisplayTimer()
    }

    func stop() {
        for nodes in perTrack.values { nodes.player.stop() }
        isPlaying = false
        currentTime = 0
        stopDisplayTimer()
    }

    func seek(to seconds: Double) {
        let wasPlaying = isPlaying
        for nodes in perTrack.values { nodes.player.stop() }
        currentTime = max(0, seconds)
        if wasPlaying { play() }
    }

    private func startDisplayTimer() {
        stopDisplayTimer()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func tick() {
        guard let project, isPlaying else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - playbackAnchorWallTime
        currentTime = playbackAnchorPosition + max(0, elapsed)

        if let loop = project.loopRegion, currentTime >= loop.upperBound {
            seek(to: loop.lowerBound)
            return
        }
        let duration = project.projectDuration
        if duration > 0, currentTime >= duration, project.loopRegion == nil {
            currentTime = duration
            stop()
        }
    }

    /// Produces the fully-processed (trim + gain + fades baked in) buffer for a clip,
    /// converting to the shared project format first if needed. Not cached across
    /// calls; callers that need repeated access (e.g. waveform previews) should cache
    /// per clip id + edit-version themselves.
    nonisolated static func processedBuffer(for clip: Clip, source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let converted = BufferFormatConverter.convert(source, to: projectFormat) ?? source
        let sampleRate = converted.format.sampleRate
        let startFrame = AVAudioFramePosition(clip.sourceStart * sampleRate)
        let endFrame = startFrame + AVAudioFramePosition(clip.duration * sampleRate)
        guard let slice = converted.slice(from: startFrame, to: endFrame) else { return nil }

        if let data = slice.floatChannelData {
            let channelCount = Int(slice.format.channelCount)
            let frameLength = Int(slice.frameLength)
            let gain = Float(clip.gain)
            if gain != 1.0 {
                for ch in 0..<channelCount {
                    for i in 0..<frameLength { data[ch][i] *= gain }
                }
            }
        }
        if clip.fadeIn > 0 {
            slice.applyFade(from: 0, to: AVAudioFramePosition(clip.fadeIn * sampleRate), fadeIn: true)
        }
        if clip.fadeOut > 0 {
            let start = AVAudioFramePosition(max(0, Double(slice.frameLength) / sampleRate - clip.fadeOut) * sampleRate)
            slice.applyFade(from: start, to: AVAudioFramePosition(slice.frameLength), fadeIn: false)
        }
        return slice
    }
}

/// Converts buffers to a common sample rate/channel layout so tracks with
/// differently-encoded source files can be mixed together.
enum BufferFormatConverter {
    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format.sampleRate == format.sampleRate && buffer.format.channelCount == format.channelCount && buffer.format.commonFormat == format.commonFormat {
            return buffer
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCapacity) else { return nil }
        var error: NSError?
        var consumed = false
        converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }
}
