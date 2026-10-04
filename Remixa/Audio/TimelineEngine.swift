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

    private final class TrackNodes {
        let player = AVAudioPlayerNode()
        let graph = EffectsGraph()
        let mixer = AVAudioMixerNode()
        var scheduledFiles: [AVAudioFile] = []
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
        if isPlaying {
            pause()
        } else {
            _ = play()
        }
    }

    @discardableResult
    func play() -> Bool {
        guard let project else { return false }
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                project.errorMessage = "再生を開始できませんでした: \(error.localizedDescription)"
                isPlaying = false
                stopDisplayTimer()
                return false
            }
        }
        syncMixState()

        let startTime = currentTime
        let startHost = mach_absolute_time() &+ AVAudioTime.hostTime(forSeconds: 0.08)

        for track in project.tracks {
            guard let nodes = perTrack[track.id] else { continue }
            nodes.player.stop()
            nodes.scheduledFiles.removeAll(keepingCapacity: false)
            for clip in track.clips where clip.timelineEnd > startTime {
                let clipInnerOffset = max(0, startTime - clip.timelineStart)
                let scheduleDelay = max(0, clip.timelineStart - startTime)
                let atHost = startHost &+ AVAudioTime.hostTime(forSeconds: scheduleDelay)

                if Self.canStreamDirectly(clip) {
                    let sourceURL = project.sourceURL(for: clip)
                    guard let file = try? AVAudioFile(forReading: sourceURL),
                          file.processingFormat.sampleRate > 0 else {
                        project.errorMessage = "クリップ「\(clip.name)」の音源を開けませんでした"
                        continue
                    }
                    let sampleRate = file.processingFormat.sampleRate
                    let fileDuration = Double(file.length) / sampleRate
                    let sourceStart = min(fileDuration, max(0, clip.sourceStart))
                    let sourceDuration = min(max(0, clip.duration), fileDuration - sourceStart)
                    let elapsed = min(sourceDuration, clipInnerOffset)
                    let startFrame = AVAudioFramePosition((sourceStart + elapsed) * sampleRate)
                    let remaining = AVAudioFramePosition(((sourceDuration - elapsed) * sampleRate).rounded(.down))
                    guard remaining > 0, remaining <= AVAudioFramePosition(UInt32.max) else { continue }
                    nodes.player.scheduleSegment(
                        file,
                        startingFrame: startFrame,
                        frameCount: AVAudioFrameCount(remaining),
                        at: AVAudioTime(hostTime: atHost),
                        completionHandler: nil
                    )
                    nodes.scheduledFiles.append(file)
                    continue
                }

                guard let processed = project.processedBuffer(for: clip) else {
                    project.errorMessage = "クリップ「\(clip.name)」のテンポ変換に失敗しました"
                    continue
                }
                let framesPerSecond = processed.format.sampleRate
                let sliceStart = AVAudioFramePosition(clipInnerOffset * framesPerSecond)
                let scheduledBuffer: AVAudioPCMBuffer
                if sliceStart <= 0 {
                    scheduledBuffer = processed
                } else {
                    guard let slice = processed.slice(from: sliceStart, to: AVAudioFramePosition(processed.frameLength)) else { continue }
                    scheduledBuffer = slice
                }
                nodes.player.scheduleBuffer(scheduledBuffer, at: AVAudioTime(hostTime: atHost), options: [], completionHandler: nil)
            }
            nodes.player.play()
        }

        playbackAnchorWallTime = ProcessInfo.processInfo.systemUptime + 0.08
        playbackAnchorPosition = startTime
        isPlaying = true
        startDisplayTimer()
        return true
    }

    func pause() {
        for nodes in perTrack.values { nodes.player.pause() }
        isPlaying = false
        stopDisplayTimer()
    }

    func stop() {
        for nodes in perTrack.values {
            nodes.player.stop()
            nodes.scheduledFiles.removeAll(keepingCapacity: false)
        }
        isPlaying = false
        currentTime = 0
        stopDisplayTimer()
    }

    func seek(to seconds: Double) {
        let wasPlaying = isPlaying
        for nodes in perTrack.values {
            nodes.player.stop()
            nodes.scheduledFiles.removeAll(keepingCapacity: false)
        }
        currentTime = max(0, seconds)
        if wasPlaying { _ = play() }
    }

    /// Rebuilds scheduled clip buffers at the current playhead after tempo edits.
    func refreshPlaybackSchedule() {
        guard isPlaying else { return }
        let resumeAt = currentTime
        for nodes in perTrack.values { nodes.player.stop() }
        isPlaying = false
        stopDisplayTimer()
        currentTime = resumeAt
        _ = play()
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

    nonisolated static func canStreamDirectly(_ clip: Clip) -> Bool {
        clip.tempoRate == 1.0 && clip.gain == 1.0 && clip.fadeIn <= 0 && clip.fadeOut <= 0
    }

    /// Processes only the source interval already read for this clip.
    nonisolated static func processedBuffer(for clip: Clip, sourceRegion: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let converted = BufferFormatConverter.convert(sourceRegion, to: projectFormat) ?? sourceRegion
        return processTrimmedBuffer(for: clip, slice: converted)
    }

    private nonisolated static func processTrimmedBuffer(for clip: Clip, slice: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let sampleRate = slice.format.sampleRate
        let rate = min(2.0, max(0.5, clip.tempoRate))

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
            slice.applyFade(from: 0, to: AVAudioFramePosition(clip.fadeIn * rate * sampleRate), fadeIn: true)
        }
        if clip.fadeOut > 0 {
            let start = AVAudioFramePosition(max(0, Double(slice.frameLength) / sampleRate - clip.fadeOut * rate) * sampleRate)
            slice.applyFade(from: start, to: AVAudioFramePosition(slice.frameLength), fadeIn: false)
        }
        return rate == 1.0 ? slice : timeStretchedBuffer(slice, rate: rate)
    }

    /// Stretches a clip independently so clips that overlap on one track can each
    /// have their own tempo rate. AVAudioUnitTimePitch keeps pitch at 0 semitones.
    private nonisolated static func timeStretchedBuffer(_ buffer: AVAudioPCMBuffer, rate: Double) -> AVAudioPCMBuffer? {
        let format = buffer.format
        let expectedFrameCount = AVAudioFrameCount(max(1, (Double(buffer.frameLength) / rate).rounded()))
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = Float(rate)
        timePitch.pitch = 0
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)

        let maxFrames: AVAudioFrameCount = 4096
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
            try engine.start()
        } catch {
            return nil
        }
        defer { engine.stop() }

        player.scheduleBuffer(buffer, at: nil, options: [])
        player.play()

        var renderedFrames = 0
        var attempts = 0
        let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount
        )!
        guard let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: expectedFrameCount),
              let destination = result.floatChannelData else { return nil }
        let channels = Int(format.channelCount)
        // Render directly into the exact timeline-sized result to bound peak
        // memory even for long clips.
        let maximumAttempts = Int(expectedFrameCount / maxFrames) + 64
        renderLoop: while renderedFrames < Int(expectedFrameCount) && attempts < maximumAttempts {
            attempts += 1
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(maxFrames, to: outputBuffer)
            } catch {
                return nil
            }
            switch status {
            case .success:
                if outputBuffer.frameLength > 0 {
                    guard let source = outputBuffer.floatChannelData else { return nil }
                    let count = min(Int(outputBuffer.frameLength), Int(expectedFrameCount) - renderedFrames)
                    for channel in 0..<channels {
                        destination[channel].advanced(by: renderedFrames).update(from: source[channel], count: count)
                    }
                    renderedFrames += count
                }
            case .insufficientDataFromInputNode:
                // This terminal status may still carry final frames rendered
                // from other active nodes; preserve those frames before leaving.
                if outputBuffer.frameLength > 0 {
                    guard let source = outputBuffer.floatChannelData else { return nil }
                    let count = min(Int(outputBuffer.frameLength), Int(expectedFrameCount) - renderedFrames)
                    for channel in 0..<channels {
                        destination[channel].advanced(by: renderedFrames).update(from: source[channel], count: count)
                    }
                    renderedFrames += count
                }
                break renderLoop
            case .cannotDoInCurrentContext:
                continue
            case .error:
                return nil
            @unknown default:
                return nil
            }
        }

        if renderedFrames < Int(expectedFrameCount) {
            for channel in 0..<channels {
                destination[channel].advanced(by: renderedFrames).initialize(repeating: 0, count: Int(expectedFrameCount) - renderedFrames)
            }
        }
        result.frameLength = expectedFrameCount
        return result
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
