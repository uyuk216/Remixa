import AVFoundation
import Combine

/// Drives live playback of the document's buffer through the shared effects graph.
@MainActor
final class AudioEngineController: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let graph = EffectsGraph()
    private var displayTimer: Timer?

    private weak var document: AudioDocument?
    private var playbackStartFrame: AVAudioFramePosition = 0
    private var playbackStartHostTime: Double = 0
    private var currentFormat: AVAudioFormat?
    private var didBuildGraph = false

    func attach(document: AudioDocument) {
        self.document = document
    }

    private func buildGraphIfNeeded(format: AVAudioFormat) {
        guard !didBuildGraph else { return }
        engine.attach(playerNode)
        graph.attach(to: engine)
        graph.connectChain(in: engine, from: playerNode, to: engine.mainMixerNode, format: format)
        didBuildGraph = true
        currentFormat = format
    }

    func syncEffects() {
        guard let document else { return }
        graph.apply(document.effects, tempoPercent: document.tempoPercent, pitchSemitones: document.pitchSemitones)
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let document, let buffer = document.buffer else { return }
        buildGraphIfNeeded(format: buffer.format)
        syncEffects()

        if !engine.isRunning {
            try? engine.start()
        }

        let startSeconds = currentTime
        let startFrame = AVAudioFramePosition(startSeconds * document.sampleRate)
        scheduleFrom(frame: startFrame, buffer: buffer, document: document)

        playerNode.play()
        isPlaying = true
        startDisplayTimer()
    }

    private func scheduleFrom(frame startFrame: AVAudioFramePosition, buffer: AVAudioPCMBuffer, document: AudioDocument) {
        playerNode.stop()
        let totalFrames = AVAudioFramePosition(buffer.frameLength)
        let clampedStart = max(0, min(startFrame, totalFrames))
        let remaining = AVAudioFrameCount(totalFrames - clampedStart)
        guard remaining > 0, let slice = buffer.slice(from: clampedStart, to: totalFrames) else {
            isPlaying = false
            return
        }
        playbackStartFrame = clampedStart

        if document.loopEnabled, let selection = document.selection {
            let loopStart = AVAudioFramePosition(selection.lowerBound * document.sampleRate)
            let loopEnd = AVAudioFramePosition(selection.upperBound * document.sampleRate)
            if let loopSlice = buffer.slice(from: loopStart, to: loopEnd) {
                playerNode.scheduleBuffer(loopSlice, at: nil, options: .loops, completionHandler: nil)
                playbackStartFrame = loopStart
                return
            }
        }
        playerNode.scheduleBuffer(slice, at: nil, options: [], completionHandler: { [weak self] in
            Task { @MainActor in
                self?.playbackDidFinish()
            }
        })
    }

    private func playbackDidFinish() {
        isPlaying = false
        stopDisplayTimer()
    }

    func pause() {
        playerNode.pause()
        isPlaying = false
        stopDisplayTimer()
    }

    func stop() {
        playerNode.stop()
        isPlaying = false
        currentTime = 0
        stopDisplayTimer()
    }

    func seek(to seconds: Double) {
        let wasPlaying = isPlaying
        playerNode.stop()
        currentTime = seconds
        if wasPlaying {
            play()
        }
    }

    private func startDisplayTimer() {
        stopDisplayTimer()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func tick() {
        guard let document, isPlaying,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return }
        let elapsedFrames = Double(playerTime.sampleTime)
        let rate = document.tempoPercent / 100.0
        let effectiveElapsed = elapsedFrames / playerTime.sampleRate * rate
        currentTime = Double(playbackStartFrame) / document.sampleRate + effectiveElapsed
        if currentTime >= document.duration, !document.loopEnabled {
            currentTime = document.duration
            isPlaying = false
            stopDisplayTimer()
        }
    }
}
