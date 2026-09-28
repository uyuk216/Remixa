import Foundation
import AVFoundation

/// Implements every JSON-RPC method from `ai-protocol.md` against the live
/// `RemixaProject` / `TimelineEngine`. Runs entirely on the main actor so every
/// mutation goes through the same undo stack as the UI and is immediately
/// reflected in it (the `@Published` properties drive the SwiftUI views).
@MainActor
final class ControlMethods {
    private weak var project: RemixaProject?
    private weak var timelineEngine: TimelineEngine?

    struct RPCError: Error {
        let code: Int
        let message: String
        static func invalidParams(_ message: String = "不正なパラメータです") -> RPCError { RPCError(code: -32602, message: message) }
        static func appFailure(_ message: String) -> RPCError { RPCError(code: 1, message: message) }
    }

    func attach(project: RemixaProject, timelineEngine: TimelineEngine) {
        self.project = project
        self.timelineEngine = timelineEngine
    }

    /// Parses one NDJSON request line and returns the NDJSON response line
    /// (or `nil` if the line wasn't valid JSON at all).
    func handleLine(_ line: String) async -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self.encode(id: NSNull(), error: RPCError(code: -32700, message: "Parse error"))
        }
        let id = obj["id"] ?? NSNull()
        guard let method = obj["method"] as? String else {
            return Self.encode(id: id, error: RPCError(code: -32600, message: "Invalid Request"))
        }
        let params = (obj["params"] as? [String: Any]) ?? [:]

        do {
            let result = try await dispatch(method: method, params: params)
            return Self.encode(id: id, result: result)
        } catch let error as RPCError {
            return Self.encode(id: id, error: error)
        } catch {
            return Self.encode(id: id, error: RPCError.appFailure(error.localizedDescription))
        }
    }

    // MARK: - Dispatch

    private func dispatch(method: String, params: [String: Any]) async throws -> Any {
        switch method {
        case "ping":
            let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0"
            return ["version": version]

        case "project.get": return try requireProject().toJSON(timelineEngine: timelineEngine)
        case "project.new": try requireProject().resetForNewProject(); timelineEngine?.rebuildGraph(); return NSNull()
        case "project.open": return try projectOpen(params)
        case "project.save": return try projectSave(params)
        case "project.setBPM":
            let project = try requireProject()
            guard let bpm = params.number("bpm") else { throw RPCError.invalidParams("bpmが必要です") }
            project.pushUndo()
            project.bpm = bpm
            return NSNull()

        case "track.add": return try trackAdd(params)
        case "track.remove": try trackRemove(params); return NSNull()
        case "track.update": try trackUpdate(params); return NSNull()
        case "track.setEffects": try trackSetEffects(params); return NSNull()

        case "clip.add": return try clipAdd(params)
        case "clip.update": try clipUpdate(params); return NSNull()
        case "clip.split": return try clipSplit(params)
        case "clip.duplicate": return try clipDuplicate(params)
        case "clip.remove": try clipRemove(params); return NSNull()
        case "clip.process": try clipProcess(params); return NSNull()

        case "transport.play":
            let engine = try requireEngine()
            if let from = params.number("from") { engine.seek(to: from) }
            engine.play()
            return NSNull()
        case "transport.stop": try requireEngine().stop(); return NSNull()
        case "transport.seek":
            guard let time = params.number("time") else { throw RPCError.invalidParams("timeが必要です") }
            try requireEngine().seek(to: time)
            return NSNull()
        case "transport.setLoop": try transportSetLoop(params); return NSNull()

        case "export.mix": return try await exportMix(params)
        case "audio.analyze": return try audioAnalyze(params)

        case "undo": try requireProject().undo(); return NSNull()
        case "redo": try requireProject().redo(); return NSNull()

        default:
            throw RPCError(code: -32601, message: "Unknown method: \(method)")
        }
    }

    // MARK: - Helpers

    private func requireProject() throws -> RemixaProject {
        guard let project else { throw RPCError.appFailure("プロジェクトが利用できません") }
        return project
    }

    private func requireEngine() throws -> TimelineEngine {
        guard let timelineEngine else { throw RPCError.appFailure("エンジンが利用できません") }
        return timelineEngine
    }

    private func track(withID idString: String) throws -> Track {
        guard let id = UUID(uuidString: idString), let track = try requireProject().tracks.first(where: { $0.id == id }) else {
            throw RPCError.invalidParams("トラックが見つかりません: \(idString)")
        }
        return track
    }

    private func findClip(idString: String) throws -> (track: Track, index: Int) {
        guard let id = UUID(uuidString: idString) else { throw RPCError.invalidParams("不正なclipId") }
        let project = try requireProject()
        for track in project.tracks {
            if let index = track.clips.firstIndex(where: { $0.id == id }) {
                return (track, index)
            }
        }
        throw RPCError.invalidParams("クリップが見つかりません: \(idString)")
    }

    // MARK: - project.*

    private func projectOpen(_ params: [String: Any]) throws -> Any {
        guard let path = params["path"] as? String else { throw RPCError.invalidParams("pathが必要です") }
        let project = try requireProject()
        do {
            let loaded = try ProjectDocumentIO.load(from: URL(fileURLWithPath: path))
            project.tracks = loaded.tracks
            project.bpm = loaded.bpm
            project.masterVolume = loaded.masterVolume
            project.fileURL = loaded.fileURL
            project.isDirty = false
            project.bufferCache = loaded.bufferCache
            timelineEngine?.rebuildGraph()
            return NSNull()
        } catch {
            throw RPCError.appFailure("開けませんでした: \(error.localizedDescription)")
        }
    }

    private func projectSave(_ params: [String: Any]) throws -> Any {
        let project = try requireProject()
        let destination: URL
        if let path = params["path"] as? String {
            destination = URL(fileURLWithPath: path)
        } else if let existing = project.fileURL {
            destination = existing
        } else {
            throw RPCError.invalidParams("pathが必要です(未保存のプロジェクトです)")
        }
        do {
            try ProjectDocumentIO.save(project, to: destination)
            return NSNull()
        } catch {
            throw RPCError.appFailure("保存に失敗しました: \(error.localizedDescription)")
        }
    }

    // MARK: - track.*

    private func trackAdd(_ params: [String: Any]) throws -> Any {
        let project = try requireProject()
        let name = params["name"] as? String ?? "新規トラック"
        var audioURL: URL?
        if let path = params["audioPath"] as? String { audioURL = URL(fileURLWithPath: path) }
        let track = project.addTrack(named: name, audioURL: audioURL)
        var result: [String: Any] = ["trackId": track.id.uuidString]
        if let clip = track.clips.first {
            result["clipId"] = clip.id.uuidString
        }
        return result
    }

    private func trackRemove(_ params: [String: Any]) throws {
        guard let trackId = params["trackId"] as? String else { throw RPCError.invalidParams("trackIdが必要です") }
        let track = try track(withID: trackId)
        try requireProject().deleteTrack(track)
    }

    private func trackUpdate(_ params: [String: Any]) throws {
        guard let trackId = params["trackId"] as? String else { throw RPCError.invalidParams("trackIdが必要です") }
        let project = try requireProject()
        let track = try track(withID: trackId)
        project.pushUndo()
        if let name = params["name"] as? String { track.name = name }
        if let volume = params.number("volume") { track.volume = volume }
        if let pan = params.number("pan") { track.pan = pan }
        if let mute = params["mute"] as? Bool { track.mute = mute }
        if let solo = params["solo"] as? Bool { track.solo = solo }
        timelineEngine?.syncMixState()
    }

    private func trackSetEffects(_ params: [String: Any]) throws {
        guard let trackId = params["trackId"] as? String, let effectsDict = params["effects"] as? [String: Any] else {
            throw RPCError.invalidParams("trackId, effectsが必要です")
        }
        let project = try requireProject()
        let track = try track(withID: trackId)
        project.pushUndo()
        track.effects = EffectsJSON.merge(effectsDict, into: track.effects)
        timelineEngine?.syncMixState()
    }

    // MARK: - clip.*

    private func clipAdd(_ params: [String: Any]) throws -> Any {
        guard let trackId = params["trackId"] as? String, let audioPath = params["audioPath"] as? String else {
            throw RPCError.invalidParams("trackId, audioPathが必要です")
        }
        let project = try requireProject()
        let track = try track(withID: trackId)
        let start = params.number("start") ?? 0
        project.addClip(to: track, audioURL: URL(fileURLWithPath: audioPath), atTimelineStart: start)
        guard let clip = track.clips.last else { throw RPCError.appFailure("クリップの追加に失敗しました") }
        return ["clipId": clip.id.uuidString]
    }

    private func clipUpdate(_ params: [String: Any]) throws {
        guard let clipId = params["clipId"] as? String else { throw RPCError.invalidParams("clipIdが必要です") }
        let project = try requireProject()
        let (track, index) = try findClip(idString: clipId)
        project.pushUndo()
        var clip = track.clips[index]
        if let v = params.number("start") { clip.timelineStart = max(0, v) }
        if let v = params.number("sourceStart") { clip.sourceStart = max(0, v) }
        if let v = params.number("duration") { clip.duration = max(0.02, v) }
        if let v = params.number("gain") { clip.gain = v }
        if let v = params.number("fadeIn") { clip.fadeIn = v }
        if let v = params.number("fadeOut") { clip.fadeOut = v }
        track.clips[index] = clip
        project.objectWillChange.send()
    }

    private func clipSplit(_ params: [String: Any]) throws -> Any {
        guard let clipId = params["clipId"] as? String, let at = params.number("at") else {
            throw RPCError.invalidParams("clipId, atが必要です")
        }
        let project = try requireProject()
        let (track, index) = try findClip(idString: clipId)
        let clip = track.clips[index]
        guard at > clip.timelineStart, at < clip.timelineEnd else {
            throw RPCError.invalidParams("atはクリップの範囲内である必要があります")
        }
        project.splitClip(clip, on: track, at: at)
        guard let newIndex = track.clips.firstIndex(where: { $0.id == clip.id }), newIndex + 1 < track.clips.count else {
            throw RPCError.appFailure("分割に失敗しました")
        }
        return ["leftId": clip.id.uuidString, "rightId": track.clips[newIndex + 1].id.uuidString]
    }

    private func clipDuplicate(_ params: [String: Any]) throws -> Any {
        guard let clipId = params["clipId"] as? String else { throw RPCError.invalidParams("clipIdが必要です") }
        let project = try requireProject()
        let (track, index) = try findClip(idString: clipId)
        let clip = track.clips[index]
        project.duplicateClip(clip, on: track)
        guard let newClip = track.clips.last else { throw RPCError.appFailure("複製に失敗しました") }
        return ["clipId": newClip.id.uuidString]
    }

    private func clipRemove(_ params: [String: Any]) throws {
        guard let clipId = params["clipId"] as? String else { throw RPCError.invalidParams("clipIdが必要です") }
        let project = try requireProject()
        let (track, index) = try findClip(idString: clipId)
        project.deleteClip(track.clips[index], on: track)
    }

    /// Destructive render (tempo/pitch/trim baked in), reusing the v0.1
    /// `EffectsGraph` time-pitch unit, then replaces the clip's source buffer.
    private func clipProcess(_ params: [String: Any]) throws {
        guard let clipId = params["clipId"] as? String else { throw RPCError.invalidParams("clipIdが必要です") }
        let project = try requireProject()
        let (track, index) = try findClip(idString: clipId)
        let clip = track.clips[index]
        guard let sourceBuffer = project.buffer(for: clip) else {
            throw RPCError.appFailure("音声の読み込みに失敗しました")
        }

        let sampleRate = sourceBuffer.format.sampleRate
        let trimStart = params.number("trimStart") ?? 0
        let trimEnd = params.number("trimEnd") ?? (Double(sourceBuffer.frameLength) / sampleRate)
        let startFrame = AVAudioFramePosition(max(0, trimStart) * sampleRate)
        let endFrame = AVAudioFramePosition(max(trimStart, trimEnd) * sampleRate)
        guard let trimmed = sourceBuffer.slice(from: startFrame, to: endFrame), trimmed.frameLength > 0 else {
            throw RPCError.invalidParams("trimStart/trimEndが不正です")
        }

        let tempoRate = params.number("tempo") ?? 1.0
        let pitchSemitones = params.number("pitch") ?? 0.0
        guard (0.5...2.0).contains(tempoRate) else { throw RPCError.invalidParams("tempoは0.5〜2.0の範囲です") }
        guard (-12.0...12.0).contains(pitchSemitones) else { throw RPCError.invalidParams("pitchは-12〜12の範囲です") }

        let rendered = try Self.renderTempoPitch(buffer: trimmed, tempoRate: tempoRate, pitchSemitones: pitchSemitones)

        let cacheKey = "control-processed://\(UUID().uuidString)"
        project.replaceClipAudio(clip, on: track, newBuffer: rendered, cacheKey: cacheKey)
    }

    /// Offline-renders `buffer` through an `AVAudioUnitTimePitch` at the given rate/pitch.
    private static func renderTempoPitch(buffer: AVAudioPCMBuffer, tempoRate: Double, pitchSemitones: Double) throws -> AVAudioPCMBuffer {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = Float(tempoRate)
        timePitch.pitch = Float(pitchSemitones * 100.0)

        let format = buffer.format
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
        try engine.start()
        player.play()
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw RPCError.appFailure("バッファを確保できませんでした")
        }
        let estimatedTotal = Double(buffer.frameLength) / max(tempoRate, 0.01)
        var rendered: [AVAudioPCMBuffer] = []
        var renderedFrames: Double = 0

        while true {
            let framesToRender = min(maxFrames, engine.manualRenderingMaximumFrameCount)
            let status = try engine.renderOffline(framesToRender, to: outputBuffer)
            switch status {
            case .success:
                if outputBuffer.frameLength > 0, let copy = outputBuffer.deepCopy() {
                    rendered.append(copy)
                    renderedFrames += Double(outputBuffer.frameLength)
                }
            case .insufficientDataFromInputNode:
                engine.stop()
                return Self.concatenate(rendered, format: format)
            case .cannotDoInCurrentContext:
                continue
            case .error:
                throw RPCError.appFailure("オフラインレンダリングに失敗しました")
            @unknown default:
                throw RPCError.appFailure("不明なレンダリング状態です")
            }
            if renderedFrames >= estimatedTotal * 1.1 + Double(maxFrames) {
                engine.stop()
                return Self.concatenate(rendered, format: format)
            }
        }
    }

    private static func concatenate(_ buffers: [AVAudioPCMBuffer], format: AVAudioFormat) -> AVAudioPCMBuffer {
        let totalFrames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(totalFrames, 1))) else {
            return buffers.first ?? AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        }
        out.frameLength = AVAudioFrameCount(totalFrames)
        var offset = 0
        let channelCount = Int(format.channelCount)
        for buf in buffers {
            let count = Int(buf.frameLength)
            if let src = buf.floatChannelData, let dst = out.floatChannelData {
                for ch in 0..<channelCount {
                    (dst[ch] + offset).update(from: src[ch], count: count)
                }
            }
            offset += count
        }
        return out
    }

    // MARK: - transport.*

    private func transportSetLoop(_ params: [String: Any]) throws {
        guard let enabled = params["enabled"] as? Bool else { throw RPCError.invalidParams("enabledが必要です") }
        let project = try requireProject()
        if enabled {
            let start = params.number("start") ?? project.loopRegion?.lowerBound ?? 0
            let end = params.number("end") ?? project.loopRegion?.upperBound ?? project.projectDuration
            guard end > start else { throw RPCError.invalidParams("endはstartより大きい必要があります") }
            project.loopRegion = start...end
        } else {
            project.loopRegion = nil
        }
    }

    // MARK: - export.mix

    private func exportMix(_ params: [String: Any]) async throws -> Any {
        guard let path = params["path"] as? String, let formatString = params["format"] as? String else {
            throw RPCError.invalidParams("path, formatが必要です")
        }
        let format: ExportFormat
        switch formatString {
        case "wav": format = .wav
        case "m4a": format = .m4a
        default: throw RPCError.invalidParams("formatはwavかm4aです")
        }
        let project = try requireProject()

        var infos: [TimelineExporter.TrackExportInfo] = []
        let anySolo = project.anySolo
        for track in project.tracks {
            var buffers: [String: AVAudioPCMBuffer] = [:]
            for clip in track.clips {
                guard buffers[clip.audioPath] == nil, let buffer = project.buffer(for: clip) else { continue }
                buffers[clip.audioPath] = buffer
            }
            let audible = track.solo || (!anySolo && !track.mute)
            infos.append(TimelineExporter.TrackExportInfo(
                clips: track.clips, buffers: buffers, volume: track.volume, pan: track.pan,
                audible: audible, effects: track.effects
            ))
        }
        let masterVolume = project.masterVolume
        let duration = project.projectDuration
        let destination = URL(fileURLWithPath: path)

        do {
            try await TimelineExporter.export(
                tracks: infos, masterVolume: masterVolume, totalDuration: duration,
                format: format, destination: destination, progress: { _ in }
            )
            return ["path": path]
        } catch {
            throw RPCError.appFailure("書き出しに失敗しました: \(error.localizedDescription)")
        }
    }

    // MARK: - audio.analyze

    private func audioAnalyze(_ params: [String: Any]) throws -> Any {
        guard let path = params["path"] as? String else { throw RPCError.invalidParams("pathが必要です") }
        let url = URL(fileURLWithPath: path)
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let duration = Double(file.length) / format.sampleRate
            var bpm: Double? = nil
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) {
                try? file.read(into: buffer)
                bpm = BPMEstimator.estimate(buffer: buffer)
            }
            var result: [String: Any] = [
                "duration": duration,
                "sampleRate": format.sampleRate,
                "channels": Int(format.channelCount)
            ]
            if let bpm { result["bpm"] = bpm }
            return result
        } catch {
            throw RPCError.appFailure("解析に失敗しました: \(error.localizedDescription)")
        }
    }

    // MARK: - JSON-RPC envelope encoding

    private static func encode(id: Any, result: Any) -> String {
        encodeEnvelope(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func encode(id: Any, error: RPCError) -> String {
        encodeEnvelope(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
    }

    private static func encodeEnvelope(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}"
        }
        return string
    }
}

private extension Dictionary where Key == String, Value == Any {
    /// Reads a numeric parameter regardless of whether JSONSerialization produced
    /// an `NSNumber`, `Int`, or `Double` for it.
    func number(_ key: String) -> Double? {
        if let n = self[key] as? NSNumber { return n.doubleValue }
        if let d = self[key] as? Double { return d }
        if let i = self[key] as? Int { return Double(i) }
        return nil
    }
}
