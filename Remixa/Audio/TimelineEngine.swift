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
    private let metronomePlayer = AVAudioPlayerNode()
    private var perTrack: [UUID: TrackNodes] = [:]
    private weak var project: RemixaProject?
    private var displayTimer: Timer?

    private var playbackAnchorWallTime: TimeInterval = 0
    private var playbackAnchorPosition: Double = 0
    private var metronomeAttached = false
    private var metronomeBuffers: [AVAudioPCMBuffer] = []
    private var playbackGeneration = UUID()
    private var playbackPreparationTask: Task<Void, Never>?
    private var playbackPreparationWorker: Task<[TimelinePreparedPlaybackChunk], Never>?
    private var chunkStreamTasks: [Task<Void, Never>] = []
    private var playbackIsPrepared = false

    private final class TrackNodes {
        let player = AVAudioPlayerNode()
        let graph = EffectsGraph()
        let mixer = AVAudioMixerNode()
        var scheduledFiles: [AVAudioFile] = []
        var scheduledChunkFiles: [(url: URL, file: AVAudioFile)] = []
        var temporaryAudioDirectories: Set<URL> = []
    }

    nonisolated static let projectFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    nonisolated static let automationUpdateInterval = 0.03

    func attach(project: RemixaProject) {
        self.project = project
        rebuildGraph()
    }

    /// Rebuild the node graph to match `project.tracks` (call after add/remove track).
    func rebuildGraph() {
        guard let project else { return }
        let wasPlaying = isPlaying
        if wasPlaying { stop() }
        else {
            cancelPendingPlaybackWork()
            clearScheduledAudio()
        }

        if !metronomeAttached {
            engine.attach(metronomePlayer)
            engine.connect(metronomePlayer, to: engine.mainMixerNode, format: Self.projectFormat)
            metronomeAttached = true
        }

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
        applyAutomation(at: currentTime)
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
    func play(skipCountIn: Bool = false) -> Bool {
        guard let project else { return false }
        cancelPendingPlaybackWork()
        clearScheduledAudio()
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
        let countInDuration = project.countInEnabled && !skipCountIn
            ? Double(project.beatsPerBar) * 60.0 / max(project.bpm, 1)
            : 0

        let transformedPlans = project.tracks.flatMap { track in
            track.clips.compactMap { clip -> TimelinePlaybackClipPlan? in
                guard clip.timelineEnd > startTime, !Self.canStreamDirectly(clip) else { return nil }
                let outputOffset = max(0, startTime - clip.timelineStart)
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("remixa-playback-\(UUID().uuidString)", isDirectory: true)
                return TimelinePlaybackClipPlan(
                    trackID: track.id,
                    clip: clip,
                    sourceURL: project.sourceURL(for: clip),
                    outputStartFrame: Int64((outputOffset * Self.projectFormat.sampleRate).rounded()),
                    directoryURL: directory
                )
            }
        }

        let generation = UUID()
        playbackGeneration = generation
        isPlaying = true
        playbackIsPrepared = false
        stopDisplayTimer()
        if !transformedPlans.isEmpty {
            let worker = Task.detached(priority: .userInitiated) {
                await withTaskGroup(of: TimelinePreparedPlaybackChunk.self) { group in
                    var plans = transformedPlans.makeIterator()
                    for _ in 0..<min(2, transformedPlans.count) {
                        if let plan = plans.next() {
                            group.addTask { TimelineChunkRenderer.prepareFirstChunk(for: plan) }
                        }
                    }
                    var prepared: [TimelinePreparedPlaybackChunk] = []
                    while let result = await group.next() {
                        prepared.append(result)
                        if let plan = plans.next() {
                            group.addTask { TimelineChunkRenderer.prepareFirstChunk(for: plan) }
                        }
                    }
                    if Task.isCancelled {
                        Self.removeTemporaryDirectories(transformedPlans.map(\.directoryURL))
                    }
                    return prepared
                }
            }
            playbackPreparationWorker = worker
            playbackPreparationTask = Task { @MainActor [weak self] in
                let prepared = await worker.value
                guard let self else {
                    Self.removeTemporaryDirectories(transformedPlans.map(\.directoryURL))
                    return
                }
                guard self.playbackGeneration == generation, self.isPlaying else {
                    Self.removeTemporaryDirectories(transformedPlans.map(\.directoryURL))
                    return
                }
                self.playbackPreparationWorker = nil
                self.playbackPreparationTask = nil
                self.beginPlayback(
                    generation: generation,
                    startTime: startTime,
                    countInDuration: countInDuration,
                    preparedChunks: prepared
                )
            }
            return true
        }

        beginPlayback(
            generation: generation,
            startTime: startTime,
            countInDuration: countInDuration,
            preparedChunks: []
        )
        return true
    }

    private func beginPlayback(
        generation: UUID,
        startTime: Double,
        countInDuration: Double,
        preparedChunks: [TimelinePreparedPlaybackChunk]
    ) {
        guard playbackGeneration == generation, isPlaying, let project else { return }
        let startHost = mach_absolute_time() &+ AVAudioTime.hostTime(forSeconds: 0.08)
        let preparedByClipID = Dictionary(uniqueKeysWithValues: preparedChunks.map { ($0.plan.clip.id, $0) })

        for track in project.tracks {
            guard let nodes = perTrack[track.id] else { continue }
            for clip in track.clips where clip.timelineEnd > startTime {
                let clipInnerOffset = max(0, startTime - clip.timelineStart)

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
                    let scheduleDelay = max(0, clip.timelineStart - startTime)
                    let atHost = startHost &+ AVAudioTime.hostTime(forSeconds: countInDuration + scheduleDelay)
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
                guard let prepared = preparedByClipID[clip.id],
                      prepared.plan.trackID == track.id,
                      prepared.plan.clip == clip,
                      let firstChunk = prepared.chunk else {
                    if let message = preparedByClipID[clip.id]?.errorMessage {
                        project.errorMessage = message
                    }
                    if let stale = preparedByClipID[clip.id] {
                        Self.removeTemporaryDirectories([stale.plan.directoryURL])
                    }
                    continue
                }
                scheduleProcessedChunk(
                    firstChunk,
                    for: prepared.plan,
                    startTime: startTime,
                    startHost: startHost,
                    countInDuration: countInDuration,
                    generation: generation
                )
                startChunkStream(
                    for: prepared.plan,
                    after: firstChunk,
                    startTime: startTime,
                    startHost: startHost,
                    countInDuration: countInDuration,
                    generation: generation
                )
            }
            nodes.player.play()
        }

        let currentTransformedClipIDs = Set(project.tracks.flatMap(\.clips)
            .filter { !Self.canStreamDirectly($0) }
            .map(\.id))
        Self.removeTemporaryDirectories(
            preparedChunks.filter { !currentTransformedClipIDs.contains($0.plan.clip.id) }
                .map { $0.plan.directoryURL }
        )

        scheduleMetronome(
            project: project,
            startTime: startTime,
            startHost: startHost,
            countInDuration: countInDuration
        )

        playbackAnchorWallTime = ProcessInfo.processInfo.systemUptime + 0.08 + countInDuration
        playbackAnchorPosition = startTime
        playbackIsPrepared = true
        isPlaying = true
        startDisplayTimer()
    }

    private func scheduleProcessedChunk(
        _ chunk: TimelineProcessedChunk,
        for plan: TimelinePlaybackClipPlan,
        startTime: Double,
        startHost: UInt64,
        countInDuration: Double,
        generation: UUID
    ) {
        guard playbackGeneration == generation,
              isPlaying,
              let nodes = perTrack[plan.trackID] else {
            try? FileManager.default.removeItem(at: chunk.fileURL)
            return
        }
        do {
            let file = try AVAudioFile(forReading: chunk.fileURL)
            let frameCount = min(Int64(file.length), Int64(chunk.frameCount))
            guard frameCount > 0, frameCount <= Int64(UInt32.max) else {
                if nodes.temporaryAudioDirectories.contains(plan.directoryURL) {
                    try? FileManager.default.removeItem(at: chunk.fileURL)
                } else {
                    Self.removeTemporaryDirectories([plan.directoryURL])
                }
                return
            }
            let relativeStart = max(0, plan.clip.timelineStart + chunk.outputOffset - startTime)
            let atHost = startHost &+ AVAudioTime.hostTime(forSeconds: countInDuration + relativeStart)
            nodes.temporaryAudioDirectories.insert(plan.directoryURL)
            nodes.scheduledChunkFiles.append((chunk.fileURL, file))
            nodes.player.scheduleSegment(
                file,
                startingFrame: 0,
                frameCount: AVAudioFrameCount(frameCount),
                at: AVAudioTime(hostTime: atHost),
                completionHandler: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.releaseProcessedChunk(at: chunk.fileURL, trackID: plan.trackID)
                    }
                }
            )
        } catch {
            project?.errorMessage = "クリップ「\(plan.clip.name)」の変換済み音声を開けませんでした: \(error.localizedDescription)"
            if nodes.temporaryAudioDirectories.contains(plan.directoryURL) {
                try? FileManager.default.removeItem(at: chunk.fileURL)
            } else {
                Self.removeTemporaryDirectories([plan.directoryURL])
            }
        }
    }

    private func startChunkStream(
        for plan: TimelinePlaybackClipPlan,
        after firstChunk: TimelineProcessedChunk,
        startTime: Double,
        startHost: UInt64,
        countInDuration: Double,
        generation: UUID
    ) {
        guard let nodes = perTrack[plan.trackID] else { return }
        nodes.temporaryAudioDirectories.insert(plan.directoryURL)
        let nextOutputFrame = Int64(((firstChunk.outputOffset + firstChunk.outputDuration) * Self.projectFormat.sampleRate).rounded())
        let stream = TimelineChunkRenderer.chunkStream(
            for: plan,
            startingOutputFrame: nextOutputFrame,
            firstChunkIndex: 1
        )
        let task = Task { @MainActor [weak self] in
            do {
                for try await chunk in stream {
                    guard let self,
                          self.playbackGeneration == generation,
                          self.isPlaying else {
                        try? FileManager.default.removeItem(at: chunk.fileURL)
                        break
                    }
                    self.scheduleProcessedChunk(
                        chunk,
                        for: plan,
                        startTime: startTime,
                        startHost: startHost,
                        countInDuration: countInDuration,
                        generation: generation
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.playbackGeneration == generation else { return }
                self.project?.errorMessage = "クリップ「\(plan.clip.name)」の続きの変換に失敗しました: \(error.localizedDescription)"
            }
        }
        chunkStreamTasks.append(task)
    }

    private func releaseProcessedChunk(at url: URL, trackID: UUID) {
        guard let nodes = perTrack[trackID] else { return }
        nodes.scheduledChunkFiles.removeAll { entry in
            guard entry.url == url else { return false }
            try? FileManager.default.removeItem(at: url)
            return true
        }
    }

    private func cancelPendingPlaybackWork() {
        playbackGeneration = UUID()
        playbackPreparationTask?.cancel()
        playbackPreparationTask = nil
        playbackPreparationWorker?.cancel()
        playbackPreparationWorker = nil
        for task in chunkStreamTasks { task.cancel() }
        chunkStreamTasks.removeAll(keepingCapacity: false)
        playbackIsPrepared = false
    }

    private func clearScheduledAudio() {
        for nodes in perTrack.values {
            nodes.player.stop()
            nodes.scheduledFiles.removeAll(keepingCapacity: false)
            nodes.scheduledChunkFiles.removeAll(keepingCapacity: false)
            Self.removeTemporaryDirectories(Array(nodes.temporaryAudioDirectories))
            nodes.temporaryAudioDirectories.removeAll(keepingCapacity: false)
        }
    }

    private nonisolated static func removeTemporaryDirectories(_ directories: [URL]) {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func pause() {
        if !playbackIsPrepared {
            cancelPendingPlaybackWork()
            clearScheduledAudio()
        }
        for nodes in perTrack.values { nodes.player.pause() }
        metronomePlayer.stop()
        playbackIsPrepared = false
        isPlaying = false
        stopDisplayTimer()
    }

    func stop() {
        cancelPendingPlaybackWork()
        for nodes in perTrack.values {
            nodes.player.stop()
        }
        clearScheduledAudio()
        metronomePlayer.stop()
        playbackIsPrepared = false
        isPlaying = false
        currentTime = 0
        stopDisplayTimer()
    }

    func seek(to seconds: Double) {
        let wasPlaying = isPlaying
        cancelPendingPlaybackWork()
        for nodes in perTrack.values {
            nodes.player.stop()
        }
        clearScheduledAudio()
        metronomePlayer.stop()
        currentTime = max(0, seconds)
        if wasPlaying { _ = play(skipCountIn: true) }
    }

    /// Rebuilds scheduled clip buffers at the current playhead after tempo edits.
    func refreshPlaybackSchedule() {
        guard isPlaying else { return }
        let resumeAt = currentTime
        for nodes in perTrack.values { nodes.player.stop() }
        metronomePlayer.stop()
        isPlaying = false
        stopDisplayTimer()
        currentTime = resumeAt
        _ = play(skipCountIn: true)
    }

    func refreshMetronomeSettings() {
        guard let project else { return }
        metronomePlayer.volume = Float(min(1, max(0, project.metronomeVolume)))
        guard isPlaying, playbackIsPrepared else { return }
        let startHost = mach_absolute_time() &+ AVAudioTime.hostTime(forSeconds: 0.03)
        scheduleMetronome(project: project, startTime: currentTime, startHost: startHost, countInDuration: 0)
    }

    private func startDisplayTimer() {
        stopDisplayTimer()
        displayTimer = Timer.scheduledTimer(withTimeInterval: Self.automationUpdateInterval, repeats: true) { [weak self] _ in
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
        applyAutomation(at: currentTime)

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

    private func applyAutomation(at time: Double) {
        guard let project else { return }
        let anySolo = project.anySolo
        for track in project.tracks {
            guard let nodes = perTrack[track.id] else { continue }
            let audible = track.solo || (!anySolo && !track.mute)
            nodes.mixer.outputVolume = audible
                ? Float(track.automationValue(for: .volume, at: time) ?? track.volume)
                : 0
            nodes.mixer.pan = Float(track.automationValue(for: .pan, at: time) ?? track.pan)
            nodes.graph.applyAutomation(
                settings: track.effects,
                filterCutoff: track.automationValue(for: .filterCutoff, at: time),
                reverbWet: track.automationValue(for: .reverbWet, at: time),
                delayWet: track.automationValue(for: .delayWet, at: time),
                distortionWet: track.automationValue(for: .distortionWet, at: time)
            )
        }
    }

    nonisolated static func canStreamDirectly(_ clip: Clip) -> Bool {
        clip.tempoRate == 1.0 && clip.pitchSemitones == 0 && clip.gain == 1.0 && clip.fadeIn <= 0 && clip.fadeOut <= 0
    }

    /// Stretches a clip independently so clips that overlap on one track can each
    /// have their own tempo rate. Callers provide bounded source windows with preroll.
    nonisolated static func timeStretchedBuffer(_ buffer: AVAudioPCMBuffer, rate: Double, pitchSemitones: Double) -> AVAudioPCMBuffer? {
        let format = buffer.format
        let expectedFrameCount = AVAudioFrameCount(max(1, (Double(buffer.frameLength) / rate).rounded()))
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = Float(rate)
        timePitch.pitch = Float(pitchSemitones * 100)
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
        // The caller limits this result to one processing window plus preroll.
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

    private func scheduleMetronome(
        project: RemixaProject,
        startTime: Double,
        startHost: UInt64,
        countInDuration: Double
    ) {
        metronomePlayer.stop()
        guard project.playbackMetronomeEnabled || countInDuration > 0,
              project.bpm.isFinite, project.bpm > 0 else { return }

        let beatDuration = 60.0 / project.bpm
        if metronomeBuffers.isEmpty {
            metronomeBuffers = [
                Self.makeClickBuffer(frequency: 1_760, amplitude: 0.9),
                Self.makeClickBuffer(frequency: 1_320, amplitude: 0.7)
            ].compactMap { $0 }
        }
        guard metronomeBuffers.count == 2 else { return }
        metronomePlayer.volume = Float(min(1, max(0, project.metronomeVolume)))

        if countInDuration > 0 {
            for beat in 0..<project.beatsPerBar {
                let clickHost = startHost &+ AVAudioTime.hostTime(forSeconds: Double(beat) * beatDuration)
                metronomePlayer.scheduleBuffer(
                    metronomeBuffers[beat == 0 ? 0 : 1],
                    at: AVAudioTime(hostTime: clickHost),
                    options: [], completionHandler: nil
                )
            }
        }

        if project.playbackMetronomeEnabled {
            let firstBeat = max(0, Int(ceil(startTime / beatDuration - 0.000_001)))
            let endBeat = Int(ceil(project.projectDuration / beatDuration))
            if firstBeat < endBeat {
                for beat in firstBeat..<endBeat {
                    let timelineTime = Double(beat) * beatDuration
                    let delay = countInDuration + max(0, timelineTime - startTime)
                    let clickHost = startHost &+ AVAudioTime.hostTime(forSeconds: delay)
                    metronomePlayer.scheduleBuffer(
                        metronomeBuffers[beat % project.beatsPerBar == 0 ? 0 : 1],
                        at: AVAudioTime(hostTime: clickHost),
                        options: [], completionHandler: nil
                    )
                }
            }
        }
        metronomePlayer.play(at: AVAudioTime(hostTime: startHost))
    }

    private nonisolated static func makeClickBuffer(frequency: Double, amplitude: Float) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let frameCount = AVAudioFrameCount(format.sampleRate * 0.035)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frameCount
        let angularFrequency = 2 * Double.pi * frequency
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / format.sampleRate
            let envelope = exp(-time / 0.0045)
            let sample = Float(sin(angularFrequency * time) * envelope) * amplitude
            channels[0][frame] = sample
            channels[1][frame] = sample
        }
        return buffer
    }
}

struct TimelineProcessedChunk: Sendable {
    let fileURL: URL
    let outputOffset: Double
    let outputDuration: Double
    let frameCount: UInt32
}

struct TimelinePlaybackClipPlan: Sendable {
    let trackID: UUID
    let clip: Clip
    let sourceURL: URL
    let outputStartFrame: Int64
    let directoryURL: URL
}

struct TimelinePreparedPlaybackChunk: Sendable {
    let plan: TimelinePlaybackClipPlan
    let chunk: TimelineProcessedChunk?
    let errorMessage: String?
}

/// Produces bounded, preroll-backed PCM files shared by live playback and export.
/// Each source read and time-pitch render is limited to a 20-second output window.
enum TimelineChunkRenderer {
    private static let outputChunkDuration = 20.0
    private static let prerollDuration = 2.0
    private static let chunkFrameCapacity = Int64(TimelineEngine.projectFormat.sampleRate * outputChunkDuration)
    private static let maximumContextDuration = 2.0

    static func firstChunk(for plan: TimelinePlaybackClipPlan) throws -> TimelineProcessedChunk {
        try renderChunk(
            clip: plan.clip,
            sourceURL: plan.sourceURL,
            startingOutputFrame: plan.outputStartFrame,
            index: 0,
            directoryURL: plan.directoryURL
        )
    }

    static func prepareFirstChunk(for plan: TimelinePlaybackClipPlan) -> TimelinePreparedPlaybackChunk {
        do {
            return TimelinePreparedPlaybackChunk(
                plan: plan,
                chunk: try firstChunk(for: plan),
                errorMessage: nil
            )
        } catch {
            return TimelinePreparedPlaybackChunk(
                plan: plan,
                chunk: nil,
                errorMessage: "クリップ「\(plan.clip.name)」のテンポ/ピッチ変換に失敗しました: \(error.localizedDescription)"
            )
        }
    }

    static func forEachChunk(
        for clip: Clip,
        sourceURL: URL,
        directoryURL: URL,
        startingOutputFrame: Int64 = 0,
        firstChunkIndex: Int = 0,
        consume: (TimelineProcessedChunk) throws -> Void
    ) throws {
        let totalFrames = try outputFrameCount(for: clip)
        var outputFrame = max(0, startingOutputFrame)
        var index = max(0, firstChunkIndex)
        while outputFrame < totalFrames {
            try Task.checkCancellation()
            let chunk = try renderChunk(
                clip: clip,
                sourceURL: sourceURL,
                startingOutputFrame: outputFrame,
                index: index,
                directoryURL: directoryURL
            )
            try consume(chunk)
            outputFrame += Int64(chunk.frameCount)
            index += 1
        }
    }

    static func chunkStream(
        for plan: TimelinePlaybackClipPlan,
        startingOutputFrame: Int64,
        firstChunkIndex: Int
    ) -> AsyncThrowingStream<TimelineProcessedChunk, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task.detached(priority: .userInitiated) {
                do {
                    try forEachChunk(
                        for: plan.clip,
                        sourceURL: plan.sourceURL,
                        directoryURL: plan.directoryURL,
                        startingOutputFrame: startingOutputFrame,
                        firstChunkIndex: firstChunkIndex,
                        consume: { chunk in _ = continuation.yield(chunk) }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: plan.directoryURL)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { worker.cancel() }
            }
        }
    }

    private static func renderChunk(
        clip: Clip,
        sourceURL: URL,
        startingOutputFrame: Int64,
        index: Int,
        directoryURL: URL
    ) throws -> TimelineProcessedChunk {
        let rate = min(2.0, max(0.5, clip.tempoRate))
        let sampleRate = TimelineEngine.projectFormat.sampleRate
        let totalFrames = try outputFrameCount(for: clip)
        let outputStartFrame = max(0, startingOutputFrame)
        let outputFrames = min(chunkFrameCapacity, totalFrames - outputStartFrame)
        guard outputFrames > 0, outputFrames <= Int64(UInt32.max) else {
            throw NSError(domain: "Remixa", code: 34, userInfo: [
                NSLocalizedDescriptionKey: "変換する音声区間がありません"
            ])
        }

        let outputOffset = Double(outputStartFrame) / sampleRate
        let outputDuration = Double(outputFrames) / sampleRate
        let sourcePreroll = min(prerollDuration, outputOffset * rate)
        let sourceContentDuration = outputDuration * rate
        let sourceContentEnd = (outputOffset + outputDuration) * rate
        let sourcePostroll = min(maximumContextDuration, max(0, clip.duration - sourceContentEnd))
        let readStart = max(0, clip.sourceStart + outputOffset * rate - sourcePreroll)
        let readDuration = sourcePreroll + sourceContentDuration + sourcePostroll
        let sourceRegion: AVAudioPCMBuffer
        do {
            sourceRegion = try AudioFileRegionReader.read(url: sourceURL, sourceStart: readStart, duration: readDuration)
        } catch {
            throw NSError(domain: "Remixa", code: 35, userInfo: [
                NSLocalizedDescriptionKey: "テンポ/ピッチ変換用の音声を読み込めませんでした: \(error.localizedDescription)"
            ])
        }
        guard let converted = BufferFormatConverter.convert(sourceRegion, to: TimelineEngine.projectFormat) else {
            throw NSError(domain: "Remixa", code: 36, userInfo: [
                NSLocalizedDescriptionKey: "テンポ/ピッチ変換用の音声形式を変換できませんでした"
            ])
        }

        let rendered: AVAudioPCMBuffer
        if rate == 1.0 && clip.pitchSemitones == 0 {
            rendered = converted
        } else if let stretched = TimelineEngine.timeStretchedBuffer(
            converted,
            rate: rate,
            pitchSemitones: Double(clip.pitchSemitones)
        ) {
            rendered = stretched
        } else {
            throw NSError(domain: "Remixa", code: 37, userInfo: [
                NSLocalizedDescriptionKey: "テンポ/ピッチ変換を完了できませんでした"
            ])
        }

        let prerollOutputFrames = Int64((sourcePreroll / rate * sampleRate).rounded())
        guard let output = croppedBuffer(
            rendered,
            startingAt: prerollOutputFrames,
            frameCount: AVAudioFrameCount(outputFrames)
        ) else {
            throw NSError(domain: "Remixa", code: 38, userInfo: [
                NSLocalizedDescriptionKey: "変換済み音声を切り出せませんでした"
            ])
        }
        applyClipGainAndFades(
            to: output,
            clip: clip,
            outputStartFrame: outputStartFrame,
            totalOutputFrames: totalFrames
        )

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL
            .appendingPathComponent(String(format: "chunk-%08d", index))
            .appendingPathExtension("caf")
        let file = try AVAudioFile(
            forWriting: fileURL,
            settings: TimelineEngine.projectFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: output)
        return TimelineProcessedChunk(
            fileURL: fileURL,
            outputOffset: outputOffset,
            outputDuration: outputDuration,
            frameCount: UInt32(outputFrames)
        )
    }

    private static func outputFrameCount(for clip: Clip) throws -> Int64 {
        let rate = min(2.0, max(0.5, clip.tempoRate))
        let duration = clip.duration / rate
        let frames = duration * TimelineEngine.projectFormat.sampleRate
        guard duration.isFinite, duration > 0, frames.isFinite,
              frames <= Double(Int64.max) else {
            throw NSError(domain: "Remixa", code: 39, userInfo: [
                NSLocalizedDescriptionKey: "クリップの長さまたはテンポ設定が不正です"
            ])
        }
        return Int64(frames.rounded())
    }

    private static func croppedBuffer(
        _ source: AVAudioPCMBuffer,
        startingAt startFrame: Int64,
        frameCount: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard let result = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: frameCount),
              let sourceChannels = source.floatChannelData,
              let destinationChannels = result.floatChannelData else { return nil }
        result.frameLength = frameCount
        let channels = Int(source.format.channelCount)
        let sourceStart = max(0, min(startFrame, Int64(source.frameLength)))
        let availableFrames = max(0, min(Int64(frameCount), Int64(source.frameLength) - sourceStart))
        for channel in 0..<channels {
            destinationChannels[channel].initialize(repeating: 0, count: Int(frameCount))
            if availableFrames > 0 {
                destinationChannels[channel].update(
                    from: sourceChannels[channel] + Int(sourceStart),
                    count: Int(availableFrames)
                )
            }
        }
        return result
    }

    private static func applyClipGainAndFades(
        to buffer: AVAudioPCMBuffer,
        clip: Clip,
        outputStartFrame: Int64,
        totalOutputFrames: Int64
    ) {
        guard let channels = buffer.floatChannelData else { return }
        let sampleRate = buffer.format.sampleRate
        let fadeInFrames = Int64(max(0, clip.fadeIn) * sampleRate)
        let fadeOutFrames = Int64(max(0, clip.fadeOut) * sampleRate)
        let fadeOutStart = max(0, totalOutputFrames - fadeOutFrames)
        let frameCount = Int(buffer.frameLength)
        for frame in 0..<frameCount {
            let absoluteFrame = outputStartFrame + Int64(frame)
            var gain = Float(clip.gain)
            if fadeInFrames > 0, absoluteFrame < fadeInFrames {
                gain *= Float(Double(absoluteFrame) / Double(fadeInFrames))
            }
            if fadeOutFrames > 0, absoluteFrame >= fadeOutStart {
                gain *= Float(max(0, Double(totalOutputFrames - absoluteFrame - 1) / Double(fadeOutFrames)))
            }
            for channel in 0..<Int(buffer.format.channelCount) {
                channels[channel][frame] *= gain
            }
        }
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
