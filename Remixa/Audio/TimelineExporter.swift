import AVFoundation

/// Offline-renders the whole multitrack arrangement (all tracks, clips, mix state and
/// per-track effects) to a single interleaved file, mirroring `TimelineEngine`'s graph
/// so exported audio matches what's heard during live playback.
enum TimelineExporter {
    enum WAVEncoding: String, CaseIterable, Identifiable, Sendable {
        case pcm24
        case float32

        var id: Self { self }
        var title: String {
            switch self {
            case .pcm24: "24-bit PCM"
            case .float32: "32-bit float"
            }
        }
    }

    enum M4AQuality: Int, CaseIterable, Identifiable, Sendable {
        case kbps128 = 128_000
        case kbps192 = 192_000
        case kbps256 = 256_000
        case kbps320 = 320_000

        var id: Self { self }
        var title: String { "\(rawValue / 1_000) kbps" }
    }

    struct ExportOptions: Sendable {
        var wavEncoding: WAVEncoding = .pcm24
        var m4aQuality: M4AQuality = .kbps256
        var metronomeEnabled = false
        var metronomeVolume = 0.5
        var bpm = 120.0
        var beatsPerBar = 4

        init(
            wavEncoding: WAVEncoding = .pcm24,
            m4aQuality: M4AQuality = .kbps256,
            metronomeEnabled: Bool = false,
            metronomeVolume: Double = 0.5,
            bpm: Double = 120,
            beatsPerBar: Int = 4
        ) {
            self.wavEncoding = wavEncoding
            self.m4aQuality = m4aQuality
            self.metronomeEnabled = metronomeEnabled
            self.metronomeVolume = metronomeVolume
            self.bpm = bpm
            self.beatsPerBar = beatsPerBar
        }
    }

    struct TrackExportInfo: Sendable {
        struct SourceClip: Sendable {
            let clip: Clip
            let sourceURL: URL
        }

        let name: String
        let clips: [SourceClip]
        let volume: Double
        let pan: Double
        let audible: Bool
        let effects: EffectsRackSettings

        init(
            name: String = "トラック",
            clips: [SourceClip],
            volume: Double,
            pan: Double,
            audible: Bool,
            effects: EffectsRackSettings
        ) {
            self.name = name
            self.clips = clips
            self.volume = volume
            self.pan = pan
            self.audible = audible
            self.effects = effects
        }
    }

    static func export(
        tracks: [TrackExportInfo],
        masterVolume: Double,
        totalDuration: Double,
        format: ExportFormat,
        destination: URL,
        options: ExportOptions = .init(),
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard totalDuration > 0 else {
            throw NSError(domain: "Remixa", code: 30, userInfo: [NSLocalizedDescriptionKey: "書き出す長さがありません"])
        }
        let renderFormat = TimelineEngine.projectFormat
        let engine = AVAudioEngine()
        var playerNodes: [AVAudioPlayerNode] = []
        var sourceFiles: [AVAudioFile] = []
        var metronomeNode: AVAudioPlayerNode?
        var metronomeBuffers: [AVAudioPCMBuffer] = []

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
        if options.metronomeEnabled, options.metronomeVolume > 0 {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: renderFormat)
            player.volume = Float(min(1, max(0, options.metronomeVolume)))
            metronomeNode = player
        }
        engine.mainMixerNode.outputVolume = Float(masterVolume)

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: maxFrames)
        try engine.start()
        defer { engine.stop() }

        for (index, track) in tracks.enumerated() {
            let player = playerNodes[index]
            player.play()
            for sourceClip in track.clips {
                let clip = sourceClip.clip
                if TimelineEngine.canStreamDirectly(clip) {
                    let sourceFile = try AVAudioFile(forReading: sourceClip.sourceURL)
                    let sampleRate = sourceFile.processingFormat.sampleRate
                    let fileDuration = Double(sourceFile.length) / sampleRate
                    let sourceStart = min(fileDuration, max(0, clip.sourceStart))
                    let sourceDuration = min(max(0, clip.duration), fileDuration - sourceStart)
                    let frameCount = AVAudioFramePosition((sourceDuration * sampleRate).rounded(.down))
                    guard frameCount > 0, frameCount <= AVAudioFramePosition(UInt32.max) else {
                        throw NSError(domain: "Remixa", code: 31, userInfo: [
                            NSLocalizedDescriptionKey: "クリップ「\(clip.name)」の音声区間を読み込めませんでした"
                        ])
                    }
                    let startFrame = AVAudioFramePosition(sourceStart * sampleRate)
                    let sampleTime = AVAudioFramePosition(clip.timelineStart * renderFormat.sampleRate)
                    let atTime = AVAudioTime(sampleTime: sampleTime, atRate: renderFormat.sampleRate)
                    player.scheduleSegment(
                        sourceFile,
                        startingFrame: startFrame,
                        frameCount: AVAudioFrameCount(frameCount),
                        at: atTime,
                        completionHandler: nil
                    )
                    sourceFiles.append(sourceFile)
                    continue
                }
                let sourceRegion = try AudioFileRegionReader.read(
                    url: sourceClip.sourceURL, sourceStart: clip.sourceStart, duration: clip.duration
                )
                guard let processed = TimelineEngine.processedBuffer(for: clip, sourceRegion: sourceRegion) else {
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

        if let metronomeNode {
            metronomeBuffers = Self.scheduleMetronome(
                on: metronomeNode, options: options, duration: totalDuration,
                format: renderFormat
            )
        }

        let outputFile = try makeOutputFile(
            destination: destination, format: format, sourceFormat: renderFormat, options: options
        )
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
        withExtendedLifetime(sourceFiles) {}
        withExtendedLifetime(metronomeBuffers) {}
    }

    /// Writes one file per non-empty track and, if enabled, a separate click-track stem.
    static func exportStems(
        tracks: [TrackExportInfo],
        totalDuration: Double,
        format: ExportFormat,
        directory: URL,
        options: ExportOptions = .init(),
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tracksWithClips = tracks.filter { !$0.clips.isEmpty }
        let includesMetronome = options.metronomeEnabled && options.metronomeVolume > 0
        let outputCount = tracksWithClips.count + (includesMetronome ? 1 : 0)
        guard outputCount > 0 else {
            throw NSError(domain: "Remixa", code: 33, userInfo: [
                NSLocalizedDescriptionKey: "ステムを書き出すトラックがありません"
            ])
        }

        let fileExtension = format == .wav ? "wav" : "m4a"
        var completedOutputs = 0
        for (index, track) in tracksWithClips.enumerated() {
            let audibleTrack = TrackExportInfo(
                name: track.name,
                clips: track.clips,
                volume: track.volume,
                pan: track.pan,
                audible: true,
                effects: track.effects
            )
            let filename = Self.uniqueStemURL(
                directory: directory,
                name: track.name,
                number: index + 1,
                fileExtension: fileExtension
            )
            var trackOptions = options
            trackOptions.metronomeEnabled = false
            let progressOffset = Double(completedOutputs)
            let progressTotal = Double(outputCount)
            try await export(
                tracks: [audibleTrack], masterVolume: 1, totalDuration: totalDuration,
                format: format, destination: filename, options: trackOptions,
                progress: { value in
                    progress((progressOffset + value) / progressTotal)
                }
            )
            completedOutputs += 1
        }

        if includesMetronome {
            let clickURL = Self.uniqueStemURL(
                directory: directory,
                name: "メトロノーム",
                number: tracksWithClips.count + 1,
                fileExtension: fileExtension
            )
            let progressOffset = Double(completedOutputs)
            let progressTotal = Double(outputCount)
            try await export(
                tracks: [], masterVolume: 1, totalDuration: totalDuration,
                format: format, destination: clickURL, options: options,
                progress: { value in
                    progress((progressOffset + value) / progressTotal)
                }
            )
        }
        progress(1)
    }

    private static func uniqueStemURL(
        directory: URL,
        name: String,
        number: Int,
        fileExtension: String
    ) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let sanitized = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = sanitized.isEmpty ? "トラック" : sanitized
        let prefix = String(format: "%02d", number)
        var suffix = 1
        while true {
            let collisionSuffix = suffix == 1 ? "" : " (\(suffix))"
            let candidate = directory.appendingPathComponent("\(prefix)_\(baseName)\(collisionSuffix)")
                .appendingPathExtension(fileExtension)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }

    private static func scheduleMetronome(
        on player: AVAudioPlayerNode,
        options: ExportOptions,
        duration: Double,
        format: AVAudioFormat
    ) -> [AVAudioPCMBuffer] {
        guard options.bpm.isFinite, options.bpm > 0,
              options.beatsPerBar > 0, duration > 0 else { return [] }

        let beatDuration = 60 / min(400, max(20, options.bpm))
        let clickBuffers = [
            makeClickBuffer(format: format, frequency: 1_760, amplitude: 0.9),
            makeClickBuffer(format: format, frequency: 1_320, amplitude: 0.7)
        ]
        guard clickBuffers.allSatisfy({ $0 != nil }) else { return [] }
        let buffers = clickBuffers.compactMap { $0 }
        player.play()

        let beatCount = Int(ceil(duration / beatDuration))
        for beat in 0..<beatCount {
            let seconds = Double(beat) * beatDuration
            let sampleTime = AVAudioFramePosition((seconds * format.sampleRate).rounded())
            let time = AVAudioTime(sampleTime: sampleTime, atRate: format.sampleRate)
            let buffer = beat % options.beatsPerBar == 0 ? buffers[0] : buffers[1]
            player.scheduleBuffer(buffer, at: time, options: [], completionHandler: nil)
        }
        return buffers
    }

    private static func makeClickBuffer(
        format: AVAudioFormat,
        frequency: Double,
        amplitude: Float
    ) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(format.sampleRate * 0.035)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frameCount
        let angularFrequency = 2 * Double.pi * frequency
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / format.sampleRate
            let envelope = exp(-time / 0.0045)
            let sample = Float(sin(angularFrequency * time) * envelope) * amplitude
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = sample
            }
        }
        return buffer
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

    private static func makeOutputFile(
        destination: URL,
        format: ExportFormat,
        sourceFormat: AVAudioFormat,
        options: ExportOptions
    ) throws -> AVAudioFile {
        switch format {
        case .wav:
            let isFloat = options.wavEncoding == .float32
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sourceFormat.sampleRate,
                AVNumberOfChannelsKey: sourceFormat.channelCount,
                AVLinearPCMBitDepthKey: isFloat ? 32 : 24,
                AVLinearPCMIsFloatKey: isFloat,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            return try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        case .m4a:
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sourceFormat.sampleRate,
                AVNumberOfChannelsKey: sourceFormat.channelCount,
                AVEncoderBitRateKey: options.m4aQuality.rawValue
            ]
            return try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
    }
}
