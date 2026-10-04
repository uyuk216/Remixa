import Foundation

/// JSON (de)serialization helpers used by the control server to translate between
/// the live model types and the plain dictionaries the JSON-RPC protocol expects.
/// Kept separate from `Codable` (used for `.remixa` file I/O) since the wire format
/// uses different key names/shapes than the on-disk snapshot.
enum EffectsJSON {
    static func toJSON(_ settings: EffectsRackSettings) -> [String: Any] {
        [
            "eq": [
                "bypass": settings.eq.bypass,
                "lowGainDB": settings.eq.lowGainDB,
                "midGainDB": settings.eq.midGainDB,
                "highGainDB": settings.eq.highGainDB
            ],
            "filter": [
                "bypass": settings.filter.bypass,
                "isHighPass": settings.filter.isHighPass,
                "cutoffHz": settings.filter.cutoffHz
            ],
            "reverb": [
                "bypass": settings.reverb.bypass,
                "wetDryMix": settings.reverb.wetDryMix,
                "presetIndex": settings.reverb.presetIndex
            ],
            "delay": [
                "bypass": settings.delay.bypass,
                "delayTimeSec": settings.delay.delayTimeSec,
                "feedback": settings.delay.feedback,
                "wetDryMix": settings.delay.wetDryMix
            ],
            "distortion": [
                "bypass": settings.distortion.bypass,
                "presetIndex": settings.distortion.presetIndex,
                "wetDryMix": settings.distortion.wetDryMix
            ]
        ]
    }

    /// Merges a partial JSON dictionary (any subset of keys, at any nesting level)
    /// onto `settings`, leaving everything not mentioned untouched.
    static func merge(_ json: [String: Any], into settings: EffectsRackSettings) -> EffectsRackSettings {
        var s = settings
        if let eq = json["eq"] as? [String: Any] {
            if let v = eq["bypass"] as? Bool { s.eq.bypass = v }
            if let v = eq.double("lowGainDB") { s.eq.lowGainDB = v }
            if let v = eq.double("midGainDB") { s.eq.midGainDB = v }
            if let v = eq.double("highGainDB") { s.eq.highGainDB = v }
        }
        if let filter = json["filter"] as? [String: Any] {
            if let v = filter["bypass"] as? Bool { s.filter.bypass = v }
            if let v = filter["isHighPass"] as? Bool { s.filter.isHighPass = v }
            if let v = filter.double("cutoffHz") { s.filter.cutoffHz = v }
        }
        if let reverb = json["reverb"] as? [String: Any] {
            if let v = reverb["bypass"] as? Bool { s.reverb.bypass = v }
            if let v = reverb.double("wetDryMix") { s.reverb.wetDryMix = v }
            if let v = reverb.int("presetIndex") { s.reverb.presetIndex = v }
        }
        if let delay = json["delay"] as? [String: Any] {
            if let v = delay["bypass"] as? Bool { s.delay.bypass = v }
            if let v = delay.double("delayTimeSec") { s.delay.delayTimeSec = v }
            if let v = delay.double("feedback") { s.delay.feedback = v }
            if let v = delay.double("wetDryMix") { s.delay.wetDryMix = v }
        }
        if let distortion = json["distortion"] as? [String: Any] {
            if let v = distortion["bypass"] as? Bool { s.distortion.bypass = v }
            if let v = distortion.int("presetIndex") { s.distortion.presetIndex = v }
            if let v = distortion.double("wetDryMix") { s.distortion.wetDryMix = v }
        }
        return s
    }
}

extension Dictionary where Key == String, Value == Any {
    func double(_ key: String) -> Double? {
        if let n = self[key] as? NSNumber { return n.doubleValue }
        if let d = self[key] as? Double { return d }
        if let i = self[key] as? Int { return Double(i) }
        return nil
    }

    func int(_ key: String) -> Int? {
        if let n = self[key] as? NSNumber { return n.intValue }
        if let i = self[key] as? Int { return i }
        return nil
    }
}

extension Clip {
    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "id": id.uuidString,
            "name": name,
            "sourcePath": audioPath,
            "start": timelineStart,
            "sourceStart": sourceStart,
            "duration": timelineDuration,
            "timelineDuration": timelineDuration,
            "sourceDuration": duration,
            "tempoRate": tempoRate,
            "syncToProject": syncToProject,
            "gain": gain,
            "fadeIn": fadeIn,
            "fadeOut": fadeOut
        ]
        if let sourceBPM {
            json["sourceBPM"] = sourceBPM
        } else {
            json["sourceBPM"] = NSNull()
        }
        return json
    }
}

extension Track {
    func toJSON() -> [String: Any] {
        [
            "id": id.uuidString,
            "name": name,
            "volume": volume,
            "pan": pan,
            "mute": mute,
            "solo": solo,
            "effects": EffectsJSON.toJSON(effects),
            "clips": clips.map { $0.toJSON() }
        ]
    }
}

@MainActor
extension RemixaProject {
    func toJSON(timelineEngine: TimelineEngine?) -> [String: Any] {
        [
            "name": fileURL?.deletingPathExtension().lastPathComponent ?? "無題のプロジェクト",
            "path": fileURL?.path ?? NSNull(),
            "bpm": bpm,
            "masterVolume": masterVolume,
            "playhead": timelineEngine?.currentTime ?? 0,
            "isPlaying": timelineEngine?.isPlaying ?? false,
            "loop": [
                "enabled": loopRegion != nil,
                "start": loopRegion?.lowerBound ?? 0,
                "end": loopRegion?.upperBound ?? 0
            ] as [String: Any],
            "tracks": tracks.map { $0.toJSON() }
        ]
    }
}
