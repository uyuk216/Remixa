import Foundation
import AVFoundation
import SwiftUI

/// A single audio region placed on a track's timeline.
struct Clip: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// Path to the source audio, relative to the project package's `Audio/` folder
    /// once saved; absolute file URL string until first save.
    var audioPath: String
    var isRelative: Bool

    var timelineStart: Double   // seconds, position on the shared timeline
    var sourceStart: Double     // seconds trimmed from the start of the source file
    var duration: Double        // seconds of source actually played (post-trim)

    var gain: Double = 1.0          // 0...2
    var fadeIn: Double = 0          // seconds
    var fadeOut: Double = 0         // seconds

    init(id: UUID = UUID(), name: String, audioURL: URL, timelineStart: Double, sourceStart: Double, duration: Double) {
        self.id = id
        self.name = name
        self.audioPath = audioURL.path
        self.isRelative = false
        self.timelineStart = timelineStart
        self.sourceStart = sourceStart
        self.duration = duration
    }

    var timelineEnd: Double { timelineStart + duration }

    /// Resolves the absolute file URL for this clip's source audio, given the
    /// package's Audio directory (used once `isRelative` is true after a save).
    func resolvedURL(packageAudioDir: URL?) -> URL {
        if isRelative, let dir = packageAudioDir {
            return dir.appendingPathComponent(audioPath)
        }
        return URL(fileURLWithPath: audioPath)
    }
}

/// One track on the timeline: an ordered set of non-overlapping-in-time clips plus
/// mixing state (volume/pan/mute/solo) and its own effects rack.
final class Track: ObservableObject, Identifiable, Codable {
    let id: UUID
    @Published var name: String
    @Published var clips: [Clip]
    @Published var volume: Double = 1.0     // 0...2
    @Published var pan: Double = 0          // -1...1
    @Published var mute: Bool = false
    @Published var solo: Bool = false
    @Published var effects = EffectsRackSettings()

    init(id: UUID = UUID(), name: String, clips: [Clip] = []) {
        self.id = id
        self.name = name
        self.clips = clips
    }

    // MARK: Codable (manual, because @Published properties aren't auto-Codable)

    private enum CodingKeys: String, CodingKey {
        case id, name, clips, volume, pan, mute, solo, effects
    }

    convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        let name = try c.decode(String.self, forKey: .name)
        let clips = try c.decode([Clip].self, forKey: .clips)
        self.init(id: id, name: name, clips: clips)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        mute = try c.decodeIfPresent(Bool.self, forKey: .mute) ?? false
        solo = try c.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        effects = try c.decodeIfPresent(EffectsRackSettingsCodable.self, forKey: .effects)?.settings ?? EffectsRackSettings()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(clips, forKey: .clips)
        try c.encode(volume, forKey: .volume)
        try c.encode(pan, forKey: .pan)
        try c.encode(mute, forKey: .mute)
        try c.encode(solo, forKey: .solo)
        try c.encode(EffectsRackSettingsCodable(settings: effects), forKey: .effects)
    }

    /// A deep value-copy, used for undo/redo snapshots.
    func copy() -> Track {
        let t = Track(id: id, name: name, clips: clips)
        t.volume = volume
        t.pan = pan
        t.mute = mute
        t.solo = solo
        t.effects = effects
        return t
    }
}

/// Codable bridge for `EffectsRackSettings`, which is already `Equatable`/plain-value
/// but not `Codable` in v0.1. Declared here rather than editing the v0.1 type.
struct EffectsRackSettingsCodable: Codable {
    var settings: EffectsRackSettings

    private struct EQ: Codable { var bypass: Bool; var lowGainDB: Double; var midGainDB: Double; var highGainDB: Double }
    private struct Filter: Codable { var bypass: Bool; var isHighPass: Bool; var cutoffHz: Double }
    private struct Reverb: Codable { var bypass: Bool; var wetDryMix: Double; var presetIndex: Int }
    private struct Delay: Codable { var bypass: Bool; var delayTimeSec: Double; var feedback: Double; var wetDryMix: Double }
    private struct Distortion: Codable { var bypass: Bool; var presetIndex: Int; var wetDryMix: Double }
    private struct Box: Codable { var eq: EQ; var filter: Filter; var reverb: Reverb; var delay: Delay; var distortion: Distortion }

    init(settings: EffectsRackSettings) {
        self.settings = settings
    }

    func encode(to encoder: Encoder) throws {
        let box = Box(
            eq: EQ(bypass: settings.eq.bypass, lowGainDB: settings.eq.lowGainDB, midGainDB: settings.eq.midGainDB, highGainDB: settings.eq.highGainDB),
            filter: Filter(bypass: settings.filter.bypass, isHighPass: settings.filter.isHighPass, cutoffHz: settings.filter.cutoffHz),
            reverb: Reverb(bypass: settings.reverb.bypass, wetDryMix: settings.reverb.wetDryMix, presetIndex: settings.reverb.presetIndex),
            delay: Delay(bypass: settings.delay.bypass, delayTimeSec: settings.delay.delayTimeSec, feedback: settings.delay.feedback, wetDryMix: settings.delay.wetDryMix),
            distortion: Distortion(bypass: settings.distortion.bypass, presetIndex: settings.distortion.presetIndex, wetDryMix: settings.distortion.wetDryMix)
        )
        var c = encoder.singleValueContainer()
        try c.encode(box)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let box = try c.decode(Box.self)
        var s = EffectsRackSettings()
        s.eq.bypass = box.eq.bypass; s.eq.lowGainDB = box.eq.lowGainDB; s.eq.midGainDB = box.eq.midGainDB; s.eq.highGainDB = box.eq.highGainDB
        s.filter.bypass = box.filter.bypass; s.filter.isHighPass = box.filter.isHighPass; s.filter.cutoffHz = box.filter.cutoffHz
        s.reverb.bypass = box.reverb.bypass; s.reverb.wetDryMix = box.reverb.wetDryMix; s.reverb.presetIndex = box.reverb.presetIndex
        s.delay.bypass = box.delay.bypass; s.delay.delayTimeSec = box.delay.delayTimeSec; s.delay.feedback = box.delay.feedback; s.delay.wetDryMix = box.delay.wetDryMix
        s.distortion.bypass = box.distortion.bypass; s.distortion.presetIndex = box.distortion.presetIndex; s.distortion.wetDryMix = box.distortion.wetDryMix
        self.settings = s
    }
}

/// Codable snapshot of everything persisted for a `.remixa` project, used both for
/// disk I/O and for undo/redo (see `RemixaProject.pushUndo`).
struct ProjectSnapshot: Codable {
    var bpm: Double
    var masterVolume: Double
    var tracks: [TrackSnapshot]

    struct TrackSnapshot: Codable {
        var id: UUID
        var name: String
        var clips: [Clip]
        var volume: Double
        var pan: Double
        var mute: Bool
        var solo: Bool
        var effects: EffectsRackSettingsCodable
    }
}

/// The v0.2 multitrack project. Owns tracks, transport/grid state and undo/redo.
/// Kept separate from `AudioDocument` (which remains the v0.1 single-clip editor
/// model, reused for per-clip editing) so the two feature sets don't entangle.
@MainActor
final class RemixaProject: ObservableObject {
    @Published var tracks: [Track] = []
    @Published var bpm: Double = 120
    @Published var masterVolume: Double = 1.0
    @Published var loopRegion: ClosedRange<Double>?
    @Published var snapToGrid: Bool = true
    @Published var selectedClipID: UUID?
    @Published var fileURL: URL?
    @Published var isDirty: Bool = false
    @Published var errorMessage: String?

    /// Decoded audio buffers keyed by resolved absolute file path, shared across clips
    /// that reference the same source file.
    var bufferCache: [String: AVAudioPCMBuffer] = [:]

    /// Downsampled waveform peaks (over the whole source file) keyed by resolved
    /// absolute file path, shared across clips that reference the same source file.
    struct CachedWaveform { let peaks: [Float]; let sourceDuration: Double }
    private var waveformCache: [String: CachedWaveform] = [:]

    private var undoStack: [ProjectSnapshot] = []
    private var redoStack: [ProjectSnapshot] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var projectDuration: Double {
        tracks.flatMap { $0.clips }.map(\.timelineEnd).max() ?? 0
    }

    var anySolo: Bool { tracks.contains { $0.solo } }

    init() {
        tracks = [Track(name: "トラック 1")]
    }

    // MARK: - Undo

    private func snapshot() -> ProjectSnapshot {
        ProjectSnapshot(
            bpm: bpm,
            masterVolume: masterVolume,
            tracks: tracks.map {
                ProjectSnapshot.TrackSnapshot(
                    id: $0.id, name: $0.name, clips: $0.clips,
                    volume: $0.volume, pan: $0.pan, mute: $0.mute, solo: $0.solo,
                    effects: EffectsRackSettingsCodable(settings: $0.effects)
                )
            }
        )
    }

    private func restore(_ snap: ProjectSnapshot) {
        bpm = snap.bpm
        masterVolume = snap.masterVolume
        tracks = snap.tracks.map { ts in
            let t = Track(id: ts.id, name: ts.name, clips: ts.clips)
            t.volume = ts.volume; t.pan = ts.pan; t.mute = ts.mute; t.solo = ts.solo
            t.effects = ts.effects.settings
            return t
        }
    }

    /// Call before any mutating timeline operation to make it undoable.
    func pushUndo() {
        undoStack.append(snapshot())
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        isDirty = true
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        restore(previous)
        isDirty = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        restore(next)
        isDirty = true
    }

    // MARK: - Track operations

    @discardableResult
    func addTrack(named name: String = "新規トラック", audioURL: URL? = nil, at timelineStart: Double = 0) -> Track {
        pushUndo()
        let track = Track(name: name)
        if let audioURL, let buffer = try? loadBuffer(for: audioURL) {
            let duration = Double(buffer.frameLength) / buffer.format.sampleRate
            track.clips.append(Clip(name: audioURL.deletingPathExtension().lastPathComponent, audioURL: audioURL, timelineStart: timelineStart, sourceStart: 0, duration: duration))
        }
        tracks.append(track)
        return track
    }

    /// True while the project is exactly the pristine state `init()`/`resetForNewProject()`
    /// produces: a single, empty, default-named track and no history yet. Used so that
    /// adding the very first file lands in that placeholder track instead of creating a
    /// second, redundant one.
    private var isNewAndUntouched: Bool {
        undoStack.isEmpty && tracks.count == 1 && tracks[0].clips.isEmpty
    }

    /// Adds a new track for `audioURL`, unless the project is still new and untouched
    /// (see `isNewAndUntouched`), in which case the file is placed into the existing
    /// empty first track instead of creating a second one.
    @discardableResult
    func addTrackOrFillFirstEmpty(named name: String, audioURL: URL, at timelineStart: Double = 0) -> Track {
        if isNewAndUntouched {
            let track = tracks[0]
            addClip(to: track, audioURL: audioURL, atTimelineStart: timelineStart)
            return track
        }
        return addTrack(named: name, audioURL: audioURL, at: timelineStart)
    }

    func deleteTrack(_ track: Track) {
        pushUndo()
        tracks.removeAll { $0.id == track.id }
    }

    func rename(_ track: Track, to newName: String) {
        pushUndo()
        track.name = newName
    }

    // MARK: - Clip operations

    func addClip(to track: Track, audioURL: URL, atTimelineStart timelineStart: Double) {
        guard let buffer = try? loadBuffer(for: audioURL) else {
            errorMessage = "読み込みに失敗しました: \(audioURL.lastPathComponent)"
            return
        }
        pushUndo()
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let clip = Clip(name: audioURL.deletingPathExtension().lastPathComponent, audioURL: audioURL, timelineStart: max(0, timelineStart), sourceStart: 0, duration: duration)
        track.clips.append(clip)
        objectWillChange.send()
    }

    func moveClip(_ clip: Clip, on track: Track, toTimelineStart newStart: Double, recordUndo: Bool = true) {
        guard let index = track.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        if recordUndo { pushUndo() }
        var updated = track.clips[index]
        updated.timelineStart = max(0, snapped(newStart))
        track.clips[index] = updated
        objectWillChange.send()
    }

    func trimClip(_ clip: Clip, on track: Track, newStart: Double, newDuration: Double, newSourceStart: Double) {
        guard let index = track.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        pushUndo()
        var updated = track.clips[index]
        updated.timelineStart = max(0, newStart)
        updated.duration = max(0.02, newDuration)
        updated.sourceStart = max(0, newSourceStart)
        track.clips[index] = updated
        objectWillChange.send()
    }

    func splitClip(_ clip: Clip, on track: Track, at playhead: Double) {
        guard let index = track.clips.firstIndex(where: { $0.id == clip.id }),
              playhead > clip.timelineStart, playhead < clip.timelineEnd else { return }
        pushUndo()
        let offset = playhead - clip.timelineStart
        var first = clip
        first.duration = offset
        var second = clip
        second.id = UUID()
        second.timelineStart = playhead
        second.sourceStart = clip.sourceStart + offset
        second.duration = clip.duration - offset
        track.clips[index] = first
        track.clips.insert(second, at: index + 1)
        objectWillChange.send()
    }

    func duplicateClip(_ clip: Clip, on track: Track) {
        pushUndo()
        var copy = clip
        copy.id = UUID()
        copy.timelineStart = clip.timelineEnd
        track.clips.append(copy)
        objectWillChange.send()
    }

    func deleteClip(_ clip: Clip, on track: Track) {
        pushUndo()
        track.clips.removeAll { $0.id == clip.id }
        if selectedClipID == clip.id { selectedClipID = nil }
    }

    /// Replaces a clip's audio wholesale (used when the v0.1 clip editor commits an edit).
    func replaceClipAudio(_ clip: Clip, on track: Track, newBuffer: AVAudioPCMBuffer, cacheKey: String) {
        guard let index = track.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        pushUndo()
        bufferCache[cacheKey] = newBuffer
        var updated = track.clips[index]
        updated.audioPath = cacheKey
        updated.isRelative = false
        updated.sourceStart = 0
        updated.duration = Double(newBuffer.frameLength) / newBuffer.format.sampleRate
        track.clips[index] = updated
        objectWillChange.send()
    }

    private func snapped(_ seconds: Double) -> Double {
        guard snapToGrid, bpm > 0 else { return seconds }
        let beat = 60.0 / bpm
        return (seconds / beat).rounded() * beat
    }

    // MARK: - Audio loading

    /// Loads (and caches) the PCM buffer for a clip's resolved source file.
    func loadBuffer(for url: URL) throws -> AVAudioPCMBuffer {
        let key = url.path
        if let cached = bufferCache[key] { return cached }
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "Remixa", code: 10, userInfo: [NSLocalizedDescriptionKey: "バッファを確保できませんでした"])
        }
        try file.read(into: buffer)
        bufferCache[key] = buffer
        return buffer
    }

    func buffer(for clip: Clip) -> AVAudioPCMBuffer? {
        let url = clip.resolvedURL(packageAudioDir: fileURL?.appendingPathComponent("Audio"))
        return try? loadBuffer(for: url)
    }

    /// Downsampled peaks for the clip's whole source file (not just the trimmed
    /// region), cached by resolved file path so multiple clips sharing a source
    /// (or repeated redraws of the same clip) don't re-decode/re-downsample.
    func waveform(for clip: Clip) -> CachedWaveform? {
        let url = clip.resolvedURL(packageAudioDir: fileURL?.appendingPathComponent("Audio"))
        let key = url.path
        if let cached = waveformCache[key] { return cached }
        guard let buffer = try? loadBuffer(for: url) else { return nil }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let peaks = WaveformGenerator.peaks(from: buffer, targetCount: 800)
        let result = CachedWaveform(peaks: peaks, sourceDuration: duration)
        waveformCache[key] = result
        return result
    }

    // MARK: - AI stem separation (v0.3)

    /// Separates the given clip's audio (respecting its trim: `sourceStart`/`duration`)
    /// into stems via `StemSeparationService`, adds one new track per stem
    /// (ボーカル/ドラム/ベース/その他) with a clip placed at the same timeline start as
    /// the original, and mutes the original track. Recorded as a single undo step.
    /// Returns the new tracks' ids.
    @discardableResult
    func separateIntoStems(clipId: UUID, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async throws -> [UUID] {
        guard let (track, clip) = findClip(clipId) else {
            throw NSError(domain: "Remixa", code: 40, userInfo: [NSLocalizedDescriptionKey: "クリップが見つかりません"])
        }
        guard let sourceBuffer = try? loadBuffer(for: clip.resolvedURL(packageAudioDir: fileURL?.appendingPathComponent("Audio"))) else {
            throw NSError(domain: "Remixa", code: 41, userInfo: [NSLocalizedDescriptionKey: "音声を読み込めませんでした"])
        }

        // Render just the clip's trimmed region to a temp wav for Demucs to consume.
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("remixa-stem-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let regionURL = tmpDir.appendingPathComponent("region.wav")
        try Self.writeRegion(of: sourceBuffer, sourceStart: clip.sourceStart, duration: clip.duration, to: regionURL)

        let outputDir: URL
        if let fileURL {
            outputDir = fileURL.appendingPathComponent("Audio", isDirectory: true).appendingPathComponent("stems-\(clip.id.uuidString)", isDirectory: true)
        } else {
            outputDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Remixa", isDirectory: true)
                .appendingPathComponent("stems-output", isDirectory: true)
                .appendingPathComponent(clip.id.uuidString, isDirectory: true)
        }

        let stems = try await StemSeparationService.shared.separate(audioURL: regionURL, outputDir: outputDir, progress: progress)
        try? FileManager.default.removeItem(at: tmpDir)

        pushUndo()
        var newTrackIDs: [UUID] = []
        for stem in stems {
            guard let stemBuffer = try? loadBuffer(for: stem.url) else { continue }
            let duration = Double(stemBuffer.frameLength) / stemBuffer.format.sampleRate
            let newTrack = Track(name: Self.japaneseStemName(for: stem.name))
            let newClip = Clip(name: newTrack.name, audioURL: stem.url, timelineStart: clip.timelineStart, sourceStart: 0, duration: duration)
            newTrack.clips.append(newClip)
            tracks.append(newTrack)
            newTrackIDs.append(newTrack.id)
        }
        track.mute = true
        objectWillChange.send()
        return newTrackIDs
    }

    private func findClip(_ id: UUID) -> (Track, Clip)? {
        for track in tracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                return (track, clip)
            }
        }
        return nil
    }

    private static func japaneseStemName(for demucsName: String) -> String {
        switch demucsName.lowercased() {
        case "vocals": return "ボーカル"
        case "drums": return "ドラム"
        case "bass": return "ベース"
        case "other": return "その他"
        default: return demucsName
        }
    }

    /// Writes `[sourceStart, sourceStart + duration)` of `buffer` to `url` as a wav file.
    private static func writeRegion(of buffer: AVAudioPCMBuffer, sourceStart: Double, duration: Double, to url: URL) throws {
        let format = buffer.format
        let startFrame = AVAudioFramePosition(max(0, sourceStart) * format.sampleRate)
        let frameCount = AVAudioFrameCount(max(0, duration) * format.sampleRate)
        let endFrame = min(AVAudioFramePosition(buffer.frameLength), startFrame + AVAudioFramePosition(frameCount))
        let clampedCount = AVAudioFrameCount(max(0, endFrame - startFrame))

        guard let region = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(clampedCount, 1)) else {
            throw NSError(domain: "Remixa", code: 42, userInfo: [NSLocalizedDescriptionKey: "バッファを確保できませんでした"])
        }
        region.frameLength = clampedCount
        if clampedCount > 0, let srcData = buffer.floatChannelData, let dstData = region.floatChannelData {
            for ch in 0..<Int(format.channelCount) {
                dstData[ch].update(from: srcData[ch] + Int(startFrame), count: Int(clampedCount))
            }
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: region)
    }

    func resetForNewProject() {
        tracks = [Track(name: "トラック 1")]
        bpm = 120
        masterVolume = 1.0
        loopRegion = nil
        fileURL = nil
        isDirty = false
        bufferCache.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
