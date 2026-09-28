import AVFoundation

enum ExportFormat {
    case wav
    case m4a
}

/// Wraps a non-Sendable value so it can cross into the exporter's background task.
/// Safe here because the buffer is not mutated concurrently: the caller hands off
/// ownership before export starts and does not touch it again until completion.
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

enum AudioExporter {
    /// Renders `buffer` through the effects graph offline to `destination`, reporting 0...1 progress.
    static func export(
        buffer bufferBox: UncheckedSendableBox<AVAudioPCMBuffer>,
        settings: EffectsRackSettings,
        tempoPercent: Double,
        pitchSemitones: Double,
        format: ExportFormat,
        destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let buffer = bufferBox.value
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let graph = EffectsGraph()
        let renderFormat = buffer.format

        engine.attach(playerNode)
        graph.attach(to: engine)
        graph.connectChain(in: engine, from: playerNode, to: engine.mainMixerNode, format: renderFormat)
        graph.apply(settings, tempoPercent: tempoPercent, pitchSemitones: pitchSemitones)

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: maxFrames)

        try engine.start()
        playerNode.play()
        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)

        let outputFile = try makeOutputFile(destination: destination, format: format, sourceFormat: renderFormat)

        let outputBuffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!

        // Estimate total output frames accounting for tempo change.
        let tempoRate = max(tempoPercent / 100.0, 0.01)
        let estimatedTotalFrames = Double(buffer.frameLength) / tempoRate
        var renderedFrames: Double = 0

        while true {
            let framesToRender = min(maxFrames, engine.manualRenderingMaximumFrameCount)
            let status = try engine.renderOffline(framesToRender, to: outputBuffer)
            switch status {
            case .success:
                try outputFile.write(from: outputBuffer)
                renderedFrames += Double(outputBuffer.frameLength)
                let p = min(renderedFrames / max(estimatedTotalFrames, 1), 0.999)
                progress(p)
                if outputBuffer.frameLength == 0 { continue }
            case .insufficientDataFromInputNode:
                // Input exhausted; done.
                progress(1.0)
                engine.stop()
                return
            case .cannotDoInCurrentContext:
                continue
            case .error:
                throw NSError(domain: "Remixa", code: 2, userInfo: [NSLocalizedDescriptionKey: "オフラインレンダリングに失敗しました"])
            @unknown default:
                throw NSError(domain: "Remixa", code: 3, userInfo: [NSLocalizedDescriptionKey: "不明なレンダリング状態です"])
            }
            if renderedFrames >= estimatedTotalFrames * 1.05 {
                progress(1.0)
                engine.stop()
                return
            }
        }
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
