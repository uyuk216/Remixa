import AVFoundation

/// Offline-renders the whole multitrack arrangement (all tracks, clips, mix state and
/// per-track effects) to a single interleaved file, mirroring `TimelineEngine`'s graph
/// so exported audio matches what's heard during live playback.
enum TimelineExporter {
    struct TrackExportInfo: @unchecked Sendable {
        let clips: [Clip]
        let buffers: [String: AVAudioPCMBuffer] // keyed by clip.audioPath
        let volume: Double
        let pan: Double
        let audible: Bool
        let effects: EffectsRackSettings
    }

    static func export(
        tracks: [TrackExportInfo],
        masterVolume: Double,
        totalDuration: Double,
        format: ExportFormat,
        destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard totalDuration > 0 else {
            throw NSError(domain: "Remixa", code: 30, userInfo: [NSLocalizedDescriptionKey: "書き出す長さがありません"])
        }
        let renderFormat = TimelineEngine.projectFormat
        let engine = AVAudioEngine()
        var playerNodes: [AVAudioPlayerNode] = []

        for track in tracks {
            let player = AVAudioPlayerNode()
            let graph = EffectsGraph()
            let mixer = AVAudioMixerNode()
            engine.attach(player)
            graph.attach(to: engine)
            engine.attach(mixer)
            graph.connectChain(in: engine, from: player, to: mixer, format: renderFormat)
            engine.connect(mixer, to: engine.mainMixerNode, format: renderFormat)
            mixer.outputVolume = track.audible ? Float(track.volume) : 0
            mixer.pan = Float(track.pan)
            graph.apply(track.effects, tempoPercent: 100, pitchSemitones: 0)
            playerNodes.append(player)
        }
        engine.mainMixerNode.outputVolume = Float(masterVolume)

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: maxFrames)
        try engine.start()
        defer { engine.stop() }

        for (index, track) in tracks.enumerated() {
            let player = playerNodes[index]
            player.play()
            for clip in track.clips {
                guard let source = track.buffers[clip.audioPath] else { continue }
                guard let processed = TimelineEngine.processedBuffer(for: clip, source: source) else {
                    throw NSError(domain: "Remixa", code: 31, userInfo: [
                        NSLocalizedDescriptionKey: "クリップ「\(clip.name)」のテンポ変換に失敗しました"
                    ])
                }
                let delaySeconds = clip.timelineStart
                let sampleTime = AVAudioFramePosition(delaySeconds * renderFormat.sampleRate)
                let atTime = AVAudioTime(sampleTime: sampleTime, atRate: renderFormat.sampleRate)
                player.scheduleBuffer(processed, at: atTime, options: [], completionHandler: nil)
            }
        }

        let outputFile = try makeOutputFile(destination: destination, format: format, sourceFormat: renderFormat)
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        let sourceFrames = Int64(totalDuration * renderFormat.sampleRate)
        let maximumTailFrames = Int64(30 * renderFormat.sampleRate)
        let maximumFramesToRender = sourceFrames + maximumTailFrames
        let minimumTailFrames = Int64(0.5 * renderFormat.sampleRate)
        let quietFramesRequired = Int64(0.5 * renderFormat.sampleRate)
        let silenceThreshold: Float = 0.00025
        var renderedFrames: Int64 = 0
        var quietTailFrames: Int64 = 0

        while renderedFrames < maximumFramesToRender {
            let remaining = AVAudioFrameCount(maximumFramesToRender - renderedFrames)
            let framesToRender = min(maxFrames, min(engine.manualRenderingMaximumFrameCount, remaining))
            let status = try engine.renderOffline(framesToRender, to: outputBuffer)
            var shouldStopRendering = false
            switch status {
            case .success:
                try outputFile.write(from: outputBuffer)
                let previousFrameCount = renderedFrames
                renderedFrames += Int64(outputBuffer.frameLength)
                if renderedFrames <= sourceFrames {
                    progress(min(Double(renderedFrames) / Double(max(sourceFrames, 1)) * 0.9, 0.9))
                } else {
                    progress(min(0.99, 0.9 + 0.09 * Double(renderedFrames - sourceFrames) / Double(max(maximumTailFrames, 1))))
                }

                if renderedFrames > sourceFrames {
                    let tailFramesInBlock = renderedFrames - max(previousFrameCount, sourceFrames)
                    if Self.rms(of: outputBuffer) < silenceThreshold {
                        quietTailFrames += tailFramesInBlock
                    } else {
                        quietTailFrames = 0
                    }
                    if renderedFrames >= sourceFrames + minimumTailFrames,
                       quietTailFrames >= quietFramesRequired {
                        shouldStopRendering = true
                    }
                }
            case .insufficientDataFromInputNode:
                shouldStopRendering = true
            case .cannotDoInCurrentContext:
                continue
            case .error:
                throw NSError(domain: "Remixa", code: 31, userInfo: [NSLocalizedDescriptionKey: "オフラインレンダリングに失敗しました"])
            @unknown default:
                throw NSError(domain: "Remixa", code: 32, userInfo: [NSLocalizedDescriptionKey: "不明なレンダリング状態です"])
            }
            if shouldStopRendering || renderedFrames >= maximumFramesToRender { break }
        }
        progress(1.0)
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return .infinity }
        let frameCount = Int(buffer.frameLength)
        var squareSum: Double = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<frameCount {
                let sample = Double(channels[channel][frame])
                squareSum += sample * sample
            }
        }
        let sampleCount = Double(frameCount * Int(buffer.format.channelCount))
        return Float(sqrt(squareSum / sampleCount))
    }

    private static func makeOutputFile(destination: URL, format: ExportFormat, sourceFormat: AVAudioFormat) throws -> AVAudioFile {
        switch format {
        case .wav:
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sourceFormat.sampleRate,
                AVNumberOfChannelsKey: sourceFormat.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            return try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        case .m4a:
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sourceFormat.sampleRate,
                AVNumberOfChannelsKey: sourceFormat.channelCount,
                AVEncoderBitRateKey: 256000
            ]
            return try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
    }
}
