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
            project.setBPM(bpm)
            timelineEngine?.refreshPlaybackSchedule()
            return NSNull()
        case "project.setTimelineSettings": try projectSetTimelineSettings(params); return NSNull()
        case "project.setMetronome": try projectSetMetronome(params); return NSNull()
        case "project.setKey": try projectSetKey(params); return NSNull()

        case "marker.add": return try markerAdd(params)
        case "marker.update": try markerUpdate(params); return NSNull()
        case "marker.remove": try markerRemove(params); return NSNull()

        case "track.add": return try trackAdd(params)
        case "track.remove": try trackRemove(params); return NSNull()
        case "track.update": try trackUpdate(params); return NSNull()
        case "track.setEffects": try trackSetEffects(params); return NSNull()
        case "automation.set": try automationSet(params); return NSNull()

        case "clip.add": return try clipAdd(params)
        case "clip.update": try clipUpdate(params); return NSNull()
        case "clip.syncTempo": try clipSyncTempo(params); return NSNull()
        case "clip.detectKey": return try await clipDetectKey(params)
        case "clip.split": return try clipSplit(params)
        case "clip.duplicate": return try clipDuplicate(params)
        case "clip.remove": try clipRemove(params); return NSNull()
        case "clip.process": try clipProcess(params); return NSNull()

        case "transport.play":
            let engine = try requireEngine()
            if let from = params.number("from") { engine.seek(to: from) }
            guard engine.play() else {
                throw RPCError.appFailure(project?.errorMessage ?? "再生を開始できませんでした")
            }
            return NSNull()
        case "transport.stop": try requireEngine().stop(); return NSNull()
        case "transport.seek":
            guard let time = params.number("time") else { throw RPCError.invalidParams("timeが必要です") }
            try requireEngine().seek(to: time)
            return NSNull()
        case "transport.setLoop": try transportSetLoop(params); return NSNull()

        case "export.mix": return try await exportMix(params)
        case "export.stems": return try await exportStems(params)
        case "audio.analyze": return try audioAnalyze(params)

        case "undo":
            try requireProject().undo()
            timelineEngine?.refreshPlaybackSchedule()
            return NSNull()
        case "redo":
            try requireProject().redo()
            timelineEngine?.refreshPlaybackSchedule()
            return NSNull()

        case "stems.status": return stemsStatus()
        case "stems.install": return try await stemsInstall()
        case "stems.separate": return try await stemsSeparate(params)

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

    private func projectSetTimelineSettings(_ params: [String: Any]) throws {
        let snap: SnapDivision?
        if let rawValue = params["snapDivision"] {
            guard let raw = rawValue as? String else { throw RPCError.invalidParams("snapDivisionは文字列で指定してください") }
            guard let value = SnapDivision(rawValue: raw) else { throw RPCError.invalidParams("snapDivisionが不正です") }
            snap = value
        } else {
            snap = nil
        }
        let signature: TimeSignature?
        if let raw = params["timeSignature"] as? String {
            guard let value = TimeSignature(rawValue: raw) else { throw RPCError.invalidParams("timeSignatureは4/4または3/4です") }
            signature = value
        } else if params["timeSignature"] != nil {
            guard let numerator = params.number("timeSignature"), numerator == 3 || numerator == 4 else {
                throw RPCError.invalidParams("timeSignatureは4/4または3/4です")
            }
            signature = numerator == 3 ? .threeFour : .fourFour
        } else {
            signature = nil
        }
        try requireProject().setTimelineSettings(snapDivision: snap, timeSignature: signature)
    }

    private func projectSetMetronome(_ params: [String: Any]) throws {
        for key in ["playbackEnabled", "exportEnabled", "countIn"] where params[key] != nil {
            guard params[key] is Bool else { throw RPCError.invalidParams("\(key)は真偽値で指定してください") }
        }
        let volume: Double?
        if params["volume"] != nil {
            guard let value = params.number("volume"), value.isFinite, (0...1).contains(value) else {
                throw RPCError.invalidParams("volumeは0〜1の範囲です")
            }
            volume = value
        } else {
            volume = nil
        }
        try requireProject().setMetronomeSettings(
            playbackEnabled: params["playbackEnabled"] as? Bool,
            exportEnabled: params["exportEnabled"] as? Bool,
            volume: volume,
            countIn: params["countIn"] as? Bool
        )
    }

    private func projectSetKey(_ params: [String: Any]) throws {
        guard let raw = params["key"] else { throw RPCError.invalidParams("keyが必要です。キー名かnullを指定してください") }
        if raw is NSNull {
            try requireProject().setProjectKey(nil)
            return
        }
        guard let text = raw as? String,
              let key = MusicalKey.all.first(where: { $0.name.caseInsensitiveCompare(text) == .orderedSame || $0.id == text }) else {
            throw RPCError.invalidParams("keyは例: Cメジャー、Aマイナー、またはnullです")
        }
        try requireProject().setProjectKey(key)
    }

    private func markerAdd(_ params: [String: Any]) throws -> Any {
        guard let time = params.number("time"), time.isFinite, time >= 0 else {
            throw RPCError.invalidParams("timeは0以上の秒数で指定してください")
        }
        if params["name"] != nil, !(params["name"] is String) {
            throw RPCError.invalidParams("nameは文字列で指定してください")
        }
        let marker = try requireProject().addMarker(at: time, name: params["name"] as? String)
        return ["markerId": marker.id.uuidString]
    }

    private func markerUpdate(_ params: [String: Any]) throws {
        guard let rawID = params["markerId"] as? String, let id = UUID(uuidString: rawID) else {
            throw RPCError.invalidParams("有効なmarkerIdが必要です")
        }
        let project = try requireProject()
        guard project.markers.contains(where: { $0.id == id }) else {
            throw RPCError.invalidParams("マーカーが見つかりません: \(rawID)")
        }
        guard params["name"] != nil || params["time"] != nil else {
            throw RPCError.invalidParams("変更するnameまたはtimeを指定してください")
        }
        if params["name"] != nil, !(params["name"] is String) {
            throw RPCError.invalidParams("nameは文字列で指定してください")
        }
        let time: Double?
        if params["time"] != nil {
            guard let value = params.number("time"), value.isFinite, value >= 0 else {
                throw RPCError.invalidParams("timeは0以上の秒数で指定してください")
            }
            time = value
        } else {
            time = nil
        }
        project.updateMarker(id: id, name: params["name"] as? String, time: time)
    }

    private func markerRemove(_ params: [String: Any]) throws {
        guard let rawID = params["markerId"] as? String, let id = UUID(uuidString: rawID) else {
            throw RPCError.invalidParams("有効なmarkerIdが必要です")
        }
        let project = try requireProject()
        guard project.markers.contains(where: { $0.id == id }) else {
            throw RPCError.invalidParams("マーカーが見つかりません: \(rawID)")
        }
        project.deleteMarker(id: id)
    }

    private func projectOpen(_ params: [String: Any]) throws -> Any {
        guard let path = params["path"] as? String else { throw RPCError.invalidParams("pathが必要です") }
        let project = try requireProject()
        do {
            let loaded = try ProjectDocumentIO.load(from: URL(fileURLWithPath: path))
            project.replaceContents(with: loaded)
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
        var audioURL: URL?
        if let path = params["audioPath"] as? String { audioURL = URL(fileURLWithPath: path) }

        let track: Track
        if let audioURL {
            let name = (params["name"] as? String) ?? audioURL.deletingPathExtension().lastPathComponent
            track = project.addTrackOrFillFirstEmpty(named: name, audioURL: audioURL)
        } else {
            let name = params["name"] as? String ?? "新規トラック"
            track = project.addTrack(named: name, audioURL: nil)
        }

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
        project.updateTrack(
            track,
            name: params["name"] as? String,
            volume: params.number("volume"),
            pan: params.number("pan"),
            mute: params["mute"] as? Bool,
            solo: params["solo"] as? Bool
        )
        timelineEngine?.syncMixState()
    }

    private func trackSetEffects(_ params: [String: Any]) throws {
        guard let trackId = params["trackId"] as? String, let effectsDict = params["effects"] as? [String: Any] else {
            throw RPCError.invalidParams("trackId, effectsが必要です")
        }
        let project = try requireProject()
        let track = try track(withID: trackId)
        project.updateTrack(track, effects: EffectsJSON.merge(effectsDict, into: track.effects))
        timelineEngine?.syncMixState()
    }

    private func automationSet(_ params: [String: Any]) throws {
        guard let trackId = params["trackId"] as? String,
              let rawParameter = params["parameter"] as? String,
              let parameter = AutomationParameter(rawValue: rawParameter),
              let rawPoints = params["points"] as? [[String: Any]] else {
            throw RPCError.invalidParams("trackId、parameter、pointsが必要です")
        }
        let range = parameter.valueRange
        let points = try rawPoints.map { point -> AutomationPoint in
            guard let time = point.double("time"), time.isFinite, time >= 0,
                  let value = point.double("value"), value.isFinite, range.contains(value) else {
                throw RPCError.invalidParams("各ポイントのtimeは0以上、valueは\(range.lowerBound)〜\(range.upperBound)で指定してください")
            }
            return AutomationPoint(time: time, value: value)
        }
        let project = try requireProject()
        let track = try track(withID: trackId)
        project.setAutomation(points, for: parameter, on: track)
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
        let clip = track.clips[index]
        let requestedPitch: Int?
        if params["pitchSemitones"] != nil {
            guard let value = params.number("pitchSemitones"), value.isFinite,
                  value.rounded(.towardZero) == value, (-12...12).contains(value) else {
                throw RPCError.invalidParams("pitchSemitonesは-12〜12の整数です")
            }
            requestedPitch = Int(value)
        } else {
            requestedPitch = nil
        }
        if params["matchProjectKey"] != nil, !(params["matchProjectKey"] is Bool) {
            throw RPCError.invalidParams("matchProjectKeyは真偽値で指定してください")
        }
        let pitchForUpdate: Int?
        if params["matchProjectKey"] as? Bool == true {
            guard let projectKey = project.projectKey, let detectedKey = clip.detectedKey else {
                throw RPCError.invalidParams("プロジェクトのキーと検出済みのクリップキーが必要です")
            }
            pitchForUpdate = MusicalKey.transposition(from: detectedKey, to: projectKey)
        } else {
            pitchForUpdate = requestedPitch
        }
        let sourceBPM: Double??
        if let sourceBPMValue = params["sourceBPM"] {
            if sourceBPMValue is NSNull {
                sourceBPM = .some(nil)
            } else if let value = params.number("sourceBPM") {
                sourceBPM = .some(value)
            } else {
                throw RPCError.invalidParams("sourceBPMは数値またはnullで指定してください")
            }
        } else {
            sourceBPM = nil
        }
        project.updateClip(
            clip,
            on: track,
            timelineStart: params.number("start"),
            sourceStart: params.number("sourceStart"),
            duration: params.number("duration"),
            tempoRate: params.number("tempoRate"),
            sourceBPM: sourceBPM,
            syncToProject: params["syncToProject"] as? Bool,
            gain: params.number("gain"),
            fadeIn: params.number("fadeIn"),
            fadeOut: params.number("fadeOut"),
            pitchSemitones: pitchForUpdate
        )
        timelineEngine?.refreshPlaybackSchedule()
    }

    private func clipDetectKey(_ params: [String: Any]) async throws -> Any {
        guard let clipId = params["clipId"] as? String else { throw RPCError.invalidParams("clipIdが必要です") }
        let project = try requireProject()
        let (track, index) = try findClip(idString: clipId)
        let clip = track.clips[index]
        let url = project.sourceURL(for: clip)
        let sourceStart = clip.sourceStart
        let duration = clip.duration
        let key = await Task.detached(priority: .userInitiated) {
            KeyDetector.estimate(fileURL: url, sourceStart: sourceStart, duration: duration)
        }.value
        guard let key else { throw RPCError.appFailure("音源のキーを推定できませんでした") }
        project.setDetectedKey(key, for: clip.id)
        return [
            "key": key.name,
            "displayName": key.displayName,
            "camelot": key.camelotNotation,
            "tonic": key.tonic,
            "mode": key.mode.rawValue
        ]
    }

    private func clipSyncTempo(_ params: [String: Any]) throws {
        guard let clipIdString = params["clipId"] as? String,
              let clipId = UUID(uuidString: clipIdString) else {
            throw RPCError.invalidParams("有効なclipIdが必要です")
        }
        try requireProject().syncClipTempo(clipId: clipId)
        timelineEngine?.refreshPlaybackSchedule()
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
        let sourceURL = project.sourceURL(for: clip)
        guard let sourceDuration = try? AudioFileRegionReader.duration(of: sourceURL) else {
            throw RPCError.appFailure("音声の読み込みに失敗しました")
        }

        let trimStart = params.number("trimStart") ?? 0
        let trimEnd = params.number("trimEnd") ?? sourceDuration
        let safeStart = max(0, trimStart)
        let safeEnd = max(trimStart, trimEnd)
        guard trimStart.isFinite, trimEnd.isFinite, safeEnd > safeStart,
              let trimmed = try? AudioFileRegionReader.read(
                url: sourceURL, sourceStart: safeStart, duration: safeEnd - safeStart
              ) else {
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
            let audible = track.solo || (!anySolo && !track.mute)
            let clips = track.clips.map {
                TimelineExporter.TrackExportInfo.SourceClip(clip: $0, sourceURL: project.sourceURL(for: $0))
            }
            infos.append(TimelineExporter.TrackExportInfo(
                name: track.name, clips: clips, volume: track.volume, pan: track.pan,
                audible: audible, effects: track.effects, automation: track.automation
            ))
        }
        let masterVolume = project.masterVolume
        let duration = project.projectDuration
        let destination = URL(fileURLWithPath: path)
        let options = try exportOptions(project: project, params: params)

        do {
            try await TimelineExporter.export(
                tracks: infos, masterVolume: masterVolume, totalDuration: duration,
                format: format, destination: destination, options: options,
                progress: { _ in }
            )
            return ["path": path]
        } catch {
            throw RPCError.appFailure("書き出しに失敗しました: \(error.localizedDescription)")
        }
    }

    private func exportStems(_ params: [String: Any]) async throws -> Any {
        guard let path = params["directory"] as? String,
              let formatString = params["format"] as? String else {
            throw RPCError.invalidParams("directory, formatが必要です")
        }
        let format: ExportFormat
        switch formatString {
        case "wav": format = .wav
        case "m4a": format = .m4a
        default: throw RPCError.invalidParams("formatはwavかm4aです")
        }
        let project = try requireProject()
        let tracks = project.tracks.map { track in
            TimelineExporter.TrackExportInfo(
                name: track.name,
                clips: track.clips.map { .init(clip: $0, sourceURL: project.sourceURL(for: $0)) },
                volume: track.volume,
                pan: track.pan,
                audible: true,
                effects: track.effects,
                automation: track.automation
            )
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let options = try exportOptions(project: project, params: params)
        do {
            try await TimelineExporter.exportStems(
                tracks: tracks,
                totalDuration: project.projectDuration,
                format: format,
                directory: directory,
                options: options,
                progress: { _ in }
            )
            return ["directory": path]
        } catch {
            throw RPCError.appFailure("ステム書き出しに失敗しました: \(error.localizedDescription)")
        }
    }

    private func exportOptions(project: RemixaProject, params: [String: Any]) throws -> TimelineExporter.ExportOptions {
        let wavEncoding: TimelineExporter.WAVEncoding
        if let rawValue = params["wavEncoding"] {
            guard let raw = rawValue as? String else { throw RPCError.invalidParams("wavEncodingは文字列で指定してください") }
            guard let encoding = TimelineExporter.WAVEncoding(rawValue: raw) else {
                throw RPCError.invalidParams("wavEncodingはpcm24またはfloat32です")
            }
            wavEncoding = encoding
        } else {
            wavEncoding = .pcm24
        }

        let m4aQuality: TimelineExporter.M4AQuality
        if params["m4aBitrate"] != nil {
            guard let bitrate = params.number("m4aBitrate"), bitrate.isFinite,
                  let quality = TimelineExporter.M4AQuality.allCases.first(where: { Double($0.rawValue) == bitrate }) else {
                throw RPCError.invalidParams("m4aBitrateは128000、192000、256000、320000のいずれかです")
            }
            m4aQuality = quality
        } else {
            m4aQuality = .kbps256
        }
        return TimelineExporter.ExportOptions(
            wavEncoding: wavEncoding,
            m4aQuality: m4aQuality,
            metronomeEnabled: project.exportMetronomeEnabled,
            metronomeVolume: project.metronomeVolume,
            bpm: project.bpm,
            beatsPerBar: project.beatsPerBar
        )
    }

    // MARK: - stems.*

    private func stemsStatusString(_ status: StemEnvironment.Status) -> (String, String?) {
        switch status {
        case .notInstalled: return ("notInstalled", nil)
        case .installing(_, let message): return ("installing", message)
        case .ready: return ("ready", nil)
        case .failed(let message): return ("failed", message)
        }
    }

    private func stemsStatus() -> Any {
        let (status, message) = stemsStatusString(StemEnvironment.shared.status)
        var result: [String: Any] = ["status": status]
        if let message { result["message"] = message }
        return result
    }

    /// Waits for the (possibly ~1GB) stem-separation environment to install.
    /// Long-running: callers must allow a generous (30 min) socket read timeout.
    private func stemsInstall() async throws -> Any {
        await StemEnvironment.shared.install(progress: { _, _ in })
        let (status, message) = stemsStatusString(StemEnvironment.shared.status)
        var result: [String: Any] = ["status": status]
        if let message { result["message"] = message }
        return result
    }

    /// Runs AI stem separation on a clip and creates one new track per stem.
    /// Long-running: callers must allow a generous (30 min) socket read timeout.
    private func stemsSeparate(_ params: [String: Any]) async throws -> Any {
        guard let clipIdString = params["clipId"] as? String, let clipId = UUID(uuidString: clipIdString) else {
            throw RPCError.invalidParams("clipIdが必要です")
        }
        let project = try requireProject()
        do {
            let trackIds = try await project.separateIntoStems(clipId: clipId)
            return ["trackIds": trackIds.map { $0.uuidString }]
        } catch {
            throw RPCError.appFailure("パート分離に失敗しました: \(error.localizedDescription)")
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
