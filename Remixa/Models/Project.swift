import Foundation
import AVFoundation
import SwiftUI

enum SnapDivision: String, Codable, CaseIterable, Sendable, Identifiable {
    case quarterBeat
    case halfBeat
    case beat
    case bar
    case off

    var id: String { rawValue }

    var japaneseName: String {
        switch self {
        case .quarterBeat: return "1/4拍"
        case .halfBeat: return "1/2拍"
        case .beat: return "1拍"
        case .bar: return "1小節"
        case .off: return "オフ"
        }
    }
}

enum TimeSignature: String, Codable, CaseIterable, Sendable, Identifiable {
    case fourFour = "4/4"
    case threeFour = "3/4"

    var id: String { rawValue }
    var beatsPerBar: Int { self == .threeFour ? 3 : 4 }
}

enum KeyMode: String, Codable, Hashable, Sendable {
    case major
    case minor
}

struct MusicalKey: Codable, Equatable, Hashable, Sendable, Identifiable {
    var tonic: Int
    var mode: KeyMode

    var id: String { "\(tonic)-\(mode.rawValue)" }
    var name: String {
        let notes = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        let note = notes[((tonic % 12) + 12) % 12]
        return "\(note)\(mode == .major ? "メジャー" : "マイナー")"
    }

    static let all: [MusicalKey] = (0..<12).flatMap { tonic in
        [MusicalKey(tonic: tonic, mode: .major), MusicalKey(tonic: tonic, mode: .minor)]
    }
}

struct ProjectMarker: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var time: Double

    init(id: UUID = UUID(), name: String, time: Double) {
        self.id = id
        self.name = name
        self.time = max(0, time)
    }
}

/// A single audio region placed on a track's timeline.
struct Clip: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    /// Path to the source audio, relative to the project package's `Audio/` folder
    /// once saved; absolute file URL string until first save.
    var audioPath: String
    var isRelative: Bool

    var timelineStart: Double   // seconds, position on the shared timeline
    var sourceStart: Double     // seconds trimmed from the start of the source file
    var duration: Double        // seconds of source actually played (post-trim)
    var tempoRate: Double = 1.0 // playback rate; duration remains measured in source seconds
    var sourceBPM: Double?
    var syncToProject: Bool = false
    var pitchSemitones: Int = 0
    var detectedKey: MusicalKey?

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

    private enum CodingKeys: String, CodingKey {
        case id, name, audioPath, isRelative, timelineStart, sourceStart, duration
        case gain, fadeIn, fadeOut, tempoRate, sourceBPM, syncToProject, pitchSemitones, detectedKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        audioPath = try c.decode(String.self, forKey: .audioPath)
        isRelative = try c.decode(Bool.self, forKey: .isRelative)
        timelineStart = try c.decode(Double.self, forKey: .timelineStart)
        sourceStart = try c.decode(Double.self, forKey: .sourceStart)
        duration = try c.decode(Double.self, forKey: .duration)
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? 1.0
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
        let decodedRate = try c.decodeIfPresent(Double.self, forKey: .tempoRate) ?? 1.0
        tempoRate = decodedRate.isFinite ? min(2.0, max(0.5, decodedRate)) : 1.0
        let decodedBPM = try c.decodeIfPresent(Double.self, forKey: .sourceBPM)
        sourceBPM = decodedBPM.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        syncToProject = try c.decodeIfPresent(Bool.self, forKey: .syncToProject) ?? false
        pitchSemitones = min(12, max(-12, try c.decodeIfPresent(Int.self, forKey: .pitchSemitones) ?? 0))
        detectedKey = try c.decodeIfPresent(MusicalKey.self, forKey: .detectedKey)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(audioPath, forKey: .audioPath)
        try c.encode(isRelative, forKey: .isRelative)
        try c.encode(timelineStart, forKey: .timelineStart)
        try c.encode(sourceStart, forKey: .sourceStart)
        try c.encode(duration, forKey: .duration)
        try c.encode(gain, forKey: .gain)
        try c.encode(fadeIn, forKey: .fadeIn)
        try c.encode(fadeOut, forKey: .fadeOut)
        try c.encode(tempoRate, forKey: .tempoRate)
        try c.encodeIfPresent(sourceBPM, forKey: .sourceBPM)
        try c.encode(syncToProject, forKey: .syncToProject)
        try c.encode(pitchSemitones, forKey: .pitchSemitones)
        try c.encodeIfPresent(detectedKey, forKey: .detectedKey)
    }

    var timelineDuration: Double { duration / min(2.0, max(0.5, tempoRate)) }
    var timelineEnd: Double { timelineStart + timelineDuration }

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
    var markers: [ProjectMarker] = []
    var snapDivision: SnapDivision = .beat
    var timeSignature: TimeSignature = .fourFour
    var playbackMetronomeEnabled: Bool = false
    var exportMetronomeEnabled: Bool = false
    var metronomeVolume: Double = 0.4
    var countInEnabled: Bool = false
    var projectKey: MusicalKey?

    private enum CodingKeys: String, CodingKey {
        case bpm, masterVolume, tracks, markers, snapDivision, timeSignature
        case playbackMetronomeEnabled, exportMetronomeEnabled, metronomeVolume, countInEnabled, projectKey
    }

    init(
        bpm: Double,
        masterVolume: Double,
        tracks: [TrackSnapshot],
        markers: [ProjectMarker] = [],
        snapDivision: SnapDivision = .beat,
        timeSignature: TimeSignature = .fourFour,
        playbackMetronomeEnabled: Bool = false,
        exportMetronomeEnabled: Bool = false,
        metronomeVolume: Double = 0.4,
        countInEnabled: Bool = false,
        projectKey: MusicalKey? = nil
    ) {
        self.bpm = bpm
        self.masterVolume = masterVolume
        self.tracks = tracks
        self.markers = markers
        self.snapDivision = snapDivision
        self.timeSignature = timeSignature
        self.playbackMetronomeEnabled = playbackMetronomeEnabled
        self.exportMetronomeEnabled = exportMetronomeEnabled
        self.metronomeVolume = min(1, max(0, metronomeVolume))
        self.countInEnabled = countInEnabled
        self.projectKey = projectKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bpm = try c.decode(Double.self, forKey: .bpm)
        masterVolume = try c.decode(Double.self, forKey: .masterVolume)
        tracks = try c.decode([TrackSnapshot].self, forKey: .tracks)
        markers = try c.decodeIfPresent([ProjectMarker].self, forKey: .markers) ?? []
        snapDivision = try c.decodeIfPresent(SnapDivision.self, forKey: .snapDivision) ?? .beat
        timeSignature = try c.decodeIfPresent(TimeSignature.self, forKey: .timeSignature) ?? .fourFour
        playbackMetronomeEnabled = try c.decodeIfPresent(Bool.self, forKey: .playbackMetronomeEnabled) ?? false
        exportMetronomeEnabled = try c.decodeIfPresent(Bool.self, forKey: .exportMetronomeEnabled) ?? false
        metronomeVolume = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .metronomeVolume) ?? 0.4))
        countInEnabled = try c.decodeIfPresent(Bool.self, forKey: .countInEnabled) ?? false
        projectKey = try c.decodeIfPresent(MusicalKey.self, forKey: .projectKey)
    }

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
    @Published var snapDivision: SnapDivision = .beat
    @Published var timeSignature: TimeSignature = .fourFour
    @Published var markers: [ProjectMarker] = []
    @Published var playbackMetronomeEnabled = false
    @Published var exportMetronomeEnabled = false
    @Published var metronomeVolume = 0.4
    @Published var countInEnabled = false
    @Published var projectKey: MusicalKey?
    @Published var selectedClipIDs: Set<UUID> = []
    @Published var previewMoveDelta: Double = 0
    @Published var fileURL: URL?
    @Published var isDirty: Bool = false
    @Published var errorMessage: String?
    @Published private(set) var mixStateRevision = 0

    /// Downsampled waveform peaks (over the whole source file) keyed by resolved
    /// absolute file path, shared across clips that reference the same source file.
    struct CachedWaveform { let peaks: [Float]; let sourceDuration: Double }
    private var waveformCache: [String: CachedWaveform] = [:]

    private struct ProcessedBufferKey: Hashable {
        let path: String
        let fileSize: Int
        let modificationTime: TimeInterval
        let sourceStart: UInt64
        let duration: UInt64
        let tempoRate: UInt64
        let pitchSemitones: Int
        let gain: UInt64
        let fadeIn: UInt64
        let fadeOut: UInt64
    }

    private struct ProcessedBufferEntry {
        let buffer: AVAudioPCMBuffer
        let byteCount: Int
        var lastAccess: UInt64
    }

    private var processedBufferCache: [ProcessedBufferKey: ProcessedBufferEntry] = [:]
    private var processedBufferCacheBytes = 0
    private var processedBufferCacheClock: UInt64 = 0
    private let processedBufferCacheLimit = 192 * 1024 * 1024

    private var undoStack: [ProjectSnapshot] = []
    private var redoStack: [ProjectSnapshot] = []
    private var coalescedUndoSnapshot: ProjectSnapshot?
    private var coalescedUndoHasChanges = false
    private(set) var projectSessionID = UUID()
    private var selectionAnchorClipID: UUID?

    var selectedClipID: UUID? {
        get {
            if let selectionAnchorClipID, selectedClipIDs.contains(selectionAnchorClipID) {
                return selectionAnchorClipID
            }
            return selectedClipIDs.sorted { $0.uuidString < $1.uuidString }.first
        }
        set {
            selectedClipIDs = newValue.map { [$0] } ?? []
            selectionAnchorClipID = newValue
        }
    }

    var beatsPerBar: Int { timeSignature.beatsPerBar }

    private struct ActiveStemRun {
        let sessionID: UUID
        let trackID: UUID
        let clipID: UUID
        let cancellation: StemSeparationService.CancellationToken
    }
    private var activeStemRuns: [UUID: ActiveStemRun] = [:]

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
            },
            markers: markers,
            snapDivision: snapDivision,
            timeSignature: timeSignature,
            playbackMetronomeEnabled: playbackMetronomeEnabled,
            exportMetronomeEnabled: exportMetronomeEnabled,
            metronomeVolume: metronomeVolume,
            countInEnabled: countInEnabled,
            projectKey: projectKey
        )
    }

    private func restore(_ snap: ProjectSnapshot) {
        bpm = snap.bpm
        masterVolume = snap.masterVolume
        markers = snap.markers
        snapDivision = snap.snapDivision
        timeSignature = snap.timeSignature
        playbackMetronomeEnabled = snap.playbackMetronomeEnabled
        exportMetronomeEnabled = snap.exportMetronomeEnabled
        metronomeVolume = snap.metronomeVolume
        countInEnabled = snap.countInEnabled
        projectKey = snap.projectKey
        tracks = snap.tracks.map { ts in
            let t = Track(id: ts.id, name: ts.name, clips: ts.clips)
            t.volume = ts.volume; t.pan = ts.pan; t.mute = ts.mute; t.solo = ts.solo
            t.effects = ts.effects.settings
            return t
        }
        mixStateRevision &+= 1
    }

    /// Call before any mutating timeline operation to make it undoable.
    func pushUndo() {
        if coalescedUndoSnapshot != nil { endUndoCoalescing() }
        appendUndoSnapshot(snapshot())
        isDirty = true
    }

    private func appendUndoSnapshot(_ previous: ProjectSnapshot) {
        undoStack.append(previous)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Starts one undoable UI gesture, such as a slider drag.
    func beginUndoCoalescing() {
        guard coalescedUndoSnapshot == nil else { return }
        coalescedUndoSnapshot = snapshot()
        coalescedUndoHasChanges = false
    }

    /// Commits all changes made during a coalesced UI gesture as one undo step.
    func endUndoCoalescing() {
        guard let previous = coalescedUndoSnapshot else { return }
        coalescedUndoSnapshot = nil
        if coalescedUndoHasChanges {
            appendUndoSnapshot(previous)
            isDirty = true
        }
        coalescedUndoHasChanges = false
    }

    private func registerEdit() {
        if coalescedUndoSnapshot != nil {
            coalescedUndoHasChanges = true
            isDirty = true
        } else {
            pushUndo()
        }
    }

    func undo() {
        if coalescedUndoSnapshot != nil { endUndoCoalescing() }
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        restore(previous)
        isDirty = true
    }

    func redo() {
        if coalescedUndoSnapshot != nil { endUndoCoalescing() }
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        restore(next)
        isDirty = true
    }

    func clearUndoHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        coalescedUndoSnapshot = nil
        coalescedUndoHasChanges = false
    }

    func selectClip(_ clipID: UUID, command: Bool = false, shift: Bool = false) {
        if shift, let anchor = selectionAnchorClipID,
           let track = tracks.first(where: { $0.clips.contains(where: { $0.id == clipID }) }) {
            let orderedClips = track.clips.sorted(by: {
                $0.timelineStart == $1.timelineStart
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.timelineStart < $1.timelineStart
            })
            if let anchorIndex = orderedClips.firstIndex(where: { $0.id == anchor }),
               let targetIndex = orderedClips.firstIndex(where: { $0.id == clipID }) {
                let lower = min(anchorIndex, targetIndex)
                let upper = max(anchorIndex, targetIndex)
                selectedClipIDs = Set(orderedClips[lower...upper].map(\.id))
                return
            }
            selectedClipIDs = [clipID]
            selectionAnchorClipID = clipID
        } else if command {
            if selectedClipIDs.contains(clipID) {
                selectedClipIDs.remove(clipID)
            } else {
                selectedClipIDs.insert(clipID)
                selectionAnchorClipID = clipID
            }
        } else {
            selectedClipIDs = [clipID]
            selectionAnchorClipID = clipID
        }
    }

    func addMarker(at seconds: Double, name: String? = nil) -> ProjectMarker {
        pushUndo()
        let marker = ProjectMarker(name: name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "マーカー \(markers.count + 1)", time: seconds)
        markers.append(marker)
        markers.sort { $0.time < $1.time }
        return marker
    }

    func updateMarker(id: UUID, name: String? = nil, time: Double? = nil) {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return }
        var updated = markers[index]
        if let name { updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? updated.name }
        if let time, time.isFinite { updated.time = max(0, time) }
        guard updated != markers[index] else { return }
        registerEdit()
        markers[index] = updated
        markers.sort { $0.time < $1.time }
    }

    func deleteMarker(id: UUID) {
        guard markers.contains(where: { $0.id == id }) else { return }
        registerEdit()
        markers.removeAll { $0.id == id }
    }

    func setTimelineSettings(snapDivision: SnapDivision? = nil, timeSignature: TimeSignature? = nil) {
        let nextSnap = snapDivision ?? self.snapDivision
        let nextSignature = timeSignature ?? self.timeSignature
        guard nextSnap != self.snapDivision || nextSignature != self.timeSignature else { return }
        registerEdit()
        self.snapDivision = nextSnap
        self.timeSignature = nextSignature
    }

    func setMetronomeSettings(
        playbackEnabled: Bool? = nil,
        exportEnabled: Bool? = nil,
        volume: Double? = nil,
        countIn: Bool? = nil
    ) {
        let nextPlayback = playbackEnabled ?? playbackMetronomeEnabled
        let nextExport = exportEnabled ?? exportMetronomeEnabled
        let nextVolume = min(1, max(0, volume ?? metronomeVolume))
        let nextCountIn = countIn ?? countInEnabled
        guard nextPlayback != playbackMetronomeEnabled || nextExport != exportMetronomeEnabled
                || nextVolume != metronomeVolume || nextCountIn != countInEnabled else { return }
        registerEdit()
        playbackMetronomeEnabled = nextPlayback
        exportMetronomeEnabled = nextExport
        metronomeVolume = nextVolume
        countInEnabled = nextCountIn
    }

    func setProjectKey(_ key: MusicalKey?) {
        guard key != projectKey else { return }
        registerEdit()
        projectKey = key
    }

    func setDetectedKey(_ key: MusicalKey, for clipID: UUID) {
        guard let (track, clip) = findClip(clipID),
              let index = track.clips.firstIndex(where: { $0.id == clipID }),
              clip.detectedKey != key else { return }
        registerEdit()
        track.clips[index].detectedKey = key
        objectWillChange.send()
    }

    func setClipPitch(_ semitones: Int, clipID: UUID) {
        guard let (track, _) = findClip(clipID),
              let index = track.clips.firstIndex(where: { $0.id == clipID }) else { return }
        let pitch = min(12, max(-12, semitones))
        guard track.clips[index].pitchSemitones != pitch else { return }
        registerEdit()
        track.clips[index].pitchSemitones = pitch
        objectWillChange.send()
    }

    func matchClipToProjectKey(clipID: UUID) throws {
        guard let projectKey,
              let (track, _) = findClip(clipID),
              let index = track.clips.firstIndex(where: { $0.id == clipID }),
              let detectedKey = track.clips[index].detectedKey else {
            throw NSError(domain: "Remixa", code: 54, userInfo: [NSLocalizedDescriptionKey: "プロジェクトのキーと検出済みのクリップキーが必要です"])
        }
        var shift = (projectKey.tonic - detectedKey.tonic + 12) % 12
        if shift > 6 { shift -= 12 }
        setClipPitch(shift, clipID: clipID)
    }

    func setPreviewMoveDelta(_ delta: Double) {
        previewMoveDelta = delta.isFinite ? delta : 0
    }

    func moveSelectedClips(by delta: Double) {
        guard delta.isFinite, delta != 0 else { previewMoveDelta = 0; return }
        let selectedClips = tracks.flatMap { $0.clips.filter { selectedClipIDs.contains($0.id) } }
        guard let earliestStart = selectedClips.map(\.timelineStart).min() else {
            previewMoveDelta = 0
            return
        }
        var sharedDelta = snapped(delta)
        if earliestStart + sharedDelta < 0 { sharedDelta = -earliestStart }
        guard sharedDelta != 0 else { previewMoveDelta = 0; return }
        var updatedByTrack: [UUID: [Clip]] = [:]
        for track in tracks {
            let updated = track.clips.map { clip -> Clip in
                guard selectedClipIDs.contains(clip.id) else { return clip }
                var copy = clip
                copy.timelineStart = max(0, clip.timelineStart + sharedDelta)
                return copy
            }
            if updated != track.clips { updatedByTrack[track.id] = updated }
        }
        previewMoveDelta = 0
        guard !updatedByTrack.isEmpty else { return }
        registerEdit()
        for track in tracks {
            if let updated = updatedByTrack[track.id] { track.clips = updated }
        }
        objectWillChange.send()
    }

    func duplicateSelectedClips() {
        let selected = tracks.flatMap { track in track.clips.filter { selectedClipIDs.contains($0.id) }.map { (track, $0) } }
        guard !selected.isEmpty else { return }
        pushUndo()
        let offset = (selected.map { $0.1.timelineEnd }.max() ?? 0) - (selected.map { $0.1.timelineStart }.min() ?? 0)
        var newIDs = Set<UUID>()
        for (track, clip) in selected {
            var copy = clip
            copy.id = UUID()
            copy.timelineStart = clip.timelineStart + offset
            track.clips.append(copy)
            newIDs.insert(copy.id)
        }
        selectedClipIDs = newIDs
        selectionAnchorClipID = newIDs.sorted { $0.uuidString < $1.uuidString }.first
        objectWillChange.send()
    }

    func deleteSelectedClips() {
        guard !selectedClipIDs.isEmpty else { return }
        pushUndo()
        let deletingIDs = selectedClipIDs
        for track in tracks {
            for clip in track.clips where deletingIDs.contains(clip.id) {
                cancelActiveStemSeparations(forClipID: clip.id)
            }
            track.clips.removeAll { deletingIDs.contains($0.id) }
        }
        selectedClipIDs.removeAll()
        objectWillChange.send()
    }

    func splitSelectedClips(at playhead: Double) {
        guard playhead.isFinite,
              tracks.contains(where: { track in
                  track.clips.contains { selectedClipIDs.contains($0.id) && playhead > $0.timelineStart && playhead < $0.timelineEnd }
              }) else { return }
        pushUndo()
        var newSelection = Set<UUID>()
        for track in tracks {
            var updatedClips: [Clip] = []
            for clip in track.clips {
                guard selectedClipIDs.contains(clip.id), playhead > clip.timelineStart, playhead < clip.timelineEnd else {
                    updatedClips.append(clip)
                    continue
                }
                cancelActiveStemSeparations(forClipID: clip.id)
                let offset = min(clip.duration, max(0, playhead - clip.timelineStart) * clip.tempoRate)
                var left = clip
                left.duration = offset
                var right = clip
                right.id = UUID()
                right.timelineStart = playhead
                right.sourceStart = clip.sourceStart + offset
                right.duration = clip.duration - offset
                updatedClips.append(left)
                updatedClips.append(right)
                newSelection.insert(left.id)
                newSelection.insert(right.id)
            }
            track.clips = updatedClips
        }
        if !newSelection.isEmpty { selectedClipIDs = newSelection }
        objectWillChange.send()
    }

    /// Replaces all persisted project content and starts a fresh undo session.
    func replaceContents(with loaded: RemixaProject) {
        cancelAllActiveStemSeparations()
        tracks = loaded.tracks
        bpm = loaded.bpm
        masterVolume = loaded.masterVolume
        markers = loaded.markers
        snapDivision = loaded.snapDivision
        timeSignature = loaded.timeSignature
        playbackMetronomeEnabled = loaded.playbackMetronomeEnabled
        exportMetronomeEnabled = loaded.exportMetronomeEnabled
        metronomeVolume = loaded.metronomeVolume
        countInEnabled = loaded.countInEnabled
        projectKey = loaded.projectKey
        loopRegion = nil
        selectedClipIDs = []
        fileURL = loaded.fileURL
        isDirty = false
        errorMessage = nil
        invalidateAudioCaches()
        clearUndoHistory()
        mixStateRevision &+= 1
    }

    func setMasterVolume(_ value: Double) {
        guard value != masterVolume else { return }
        registerEdit()
        masterVolume = value
        mixStateRevision &+= 1
    }

    func setBPM(_ value: Double) {
        guard value.isFinite, value > 0, value != bpm else { return }
        pushUndo()
        bpm = value
        for track in tracks {
            for index in track.clips.indices where track.clips[index].syncToProject {
                guard let sourceBPM = track.clips[index].sourceBPM,
                      let rate = Self.tempoRate(projectBPM: value, sourceBPM: sourceBPM) else { continue }
                track.clips[index].tempoRate = rate
            }
        }
    }

    /// Applies a complete track mixer update as one undoable edit.
    func updateTrack(
        _ track: Track,
        name: String? = nil,
        volume: Double? = nil,
        pan: Double? = nil,
        mute: Bool? = nil,
        solo: Bool? = nil,
        effects: EffectsRackSettings? = nil
    ) {
        guard tracks.contains(where: { $0.id == track.id }) else { return }
        let changes = (name.map { $0 != track.name } ?? false)
            || (volume.map { $0 != track.volume } ?? false)
            || (pan.map { $0 != track.pan } ?? false)
            || (mute.map { $0 != track.mute } ?? false)
            || (solo.map { $0 != track.solo } ?? false)
            || (effects.map { $0 != track.effects } ?? false)
        guard changes else { return }
        registerEdit()
        if let name { track.name = name }
        if let volume { track.volume = volume }
        if let pan { track.pan = pan }
        if let mute { track.mute = mute }
        if let solo { track.solo = solo }
        if let effects { track.effects = effects }
        mixStateRevision &+= 1
    }

    // MARK: - Track operations

    @discardableResult
    func addTrack(named name: String = "新規トラック", audioURL: URL? = nil, at timelineStart: Double = 0) -> Track {
        pushUndo()
        let track = Track(name: name)
        if let audioURL, let duration = try? AudioFileRegionReader.duration(of: audioURL) {
            track.clips.append(Clip(name: audioURL.deletingPathExtension().lastPathComponent, audioURL: audioURL, timelineStart: max(0, snapped(timelineStart)), sourceStart: 0, duration: duration))
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
            if !track.clips.isEmpty { track.name = name }
            return track
        }
        return addTrack(named: name, audioURL: audioURL, at: timelineStart)
    }

    func deleteTrack(_ track: Track) {
        cancelActiveStemSeparations(forTrackID: track.id)
        pushUndo()
        tracks.removeAll { $0.id == track.id }
    }

    func rename(_ track: Track, to newName: String) {
        pushUndo()
        track.name = newName
    }

    // MARK: - Clip operations

    func addClip(to track: Track, audioURL: URL, atTimelineStart timelineStart: Double) {
        guard let duration = try? AudioFileRegionReader.duration(of: audioURL) else {
            errorMessage = "読み込みに失敗しました: \(audioURL.lastPathComponent)"
            return
        }
        pushUndo()
        let clip = Clip(name: audioURL.deletingPathExtension().lastPathComponent, audioURL: audioURL, timelineStart: max(0, snapped(timelineStart)), sourceStart: 0, duration: duration)
        track.clips.append(clip)
        objectWillChange.send()
    }

    func moveClip(_ clip: Clip, on track: Track, toTimelineStart newStart: Double, recordUndo: Bool = true) {
        guard let index = track.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        var updated = track.clips[index]
        updated.timelineStart = max(0, snapped(newStart))
        guard updated != track.clips[index] else { return }
        cancelActiveStemSeparations(forClipID: clip.id)
        if recordUndo { registerEdit() }
        track.clips[index] = updated
        objectWillChange.send()
    }

    /// Slips the source audio under the clip without moving its timeline edges.
    func nudgeClipContent(_ clip: Clip, on track: Track, by timelineSeconds: Double) {
        guard timelineSeconds.isFinite,
              let index = track.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        var updated = track.clips[index]
        guard let sourceDuration = sourceDuration(for: updated) else { return }
        let latestStart = max(0, sourceDuration - updated.duration)
        updated.sourceStart = min(latestStart, max(0, updated.sourceStart + timelineSeconds * updated.tempoRate))
        guard updated != track.clips[index] else { return }
        cancelActiveStemSeparations(forClipID: clip.id)
        registerEdit()
        track.clips[index] = updated
        objectWillChange.send()
    }

    func trimClip(_ clip: Clip, on track: Track, newStart: Double, newDuration: Double, newSourceStart: Double) {
        guard let index = track.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        cancelActiveStemSeparations(forClipID: clip.id)
        pushUndo()
        var updated = track.clips[index]
        updated.timelineStart = max(0, newStart)
        if let sourceDuration = sourceDuration(for: updated) {
            let minimumDuration = min(0.02, sourceDuration)
            let latestStart = max(0, sourceDuration - minimumDuration)
            updated.sourceStart = min(max(0, newSourceStart), latestStart)
            let availableDuration = max(minimumDuration, sourceDuration - updated.sourceStart)
            updated.duration = min(max(minimumDuration, newDuration), availableDuration)
        } else {
            updated.duration = max(0.02, newDuration)
            updated.sourceStart = max(0, newSourceStart)
        }
        track.clips[index] = updated
        objectWillChange.send()
    }

    /// Updates clip state. A supplied `duration` is measured in timeline seconds;
    /// the source-region duration is adjusted using the resulting tempo rate.
    func updateClip(
        _ clip: Clip,
        on track: Track,
        timelineStart: Double? = nil,
        sourceStart: Double? = nil,
        duration: Double? = nil,
        tempoRate: Double? = nil,
        sourceBPM: Double?? = nil,
        syncToProject: Bool? = nil,
        gain: Double? = nil,
        fadeIn: Double? = nil,
        fadeOut: Double? = nil,
        pitchSemitones: Int? = nil
    ) {
        guard let index = track.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        var updated = track.clips[index]
        if let timelineStart { updated.timelineStart = max(0, timelineStart) }
        var manuallyChangedRate = false
        if let tempoRate, tempoRate.isFinite {
            let clampedRate = min(2.0, max(0.5, tempoRate))
            manuallyChangedRate = clampedRate != updated.tempoRate
            updated.tempoRate = clampedRate
        }
        if let sourceBPM {
            updated.sourceBPM = sourceBPM.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            if sourceBPM == nil, syncToProject == nil {
                updated.syncToProject = false
            }
        }
        if let syncToProject {
            updated.syncToProject = syncToProject
        } else if manuallyChangedRate {
            // An explicit manual rate detaches the clip unless the caller also
            // explicitly requests project synchronization.
            updated.syncToProject = false
        }
        if updated.syncToProject {
            if updated.sourceBPM == nil {
                updated.sourceBPM = BPMEstimator.estimate(fileURL: sourceURL(for: updated))
            }
            if let sourceBPM = updated.sourceBPM,
               let rate = Self.tempoRate(projectBPM: bpm, sourceBPM: sourceBPM) {
                updated.tempoRate = rate
            } else if syncToProject == true {
                // Do not leave a clip marked as synced when there is no BPM to
                // follow. The explicit clip.syncTempo path reports this as an error.
                updated.syncToProject = false
            }
        }
        let requestedSourceDuration = duration.map { max(0.02, $0 * updated.tempoRate) }
        if sourceStart != nil || duration != nil {
            if let sourceDuration = sourceDuration(for: updated) {
                let minimumDuration = min(0.02, sourceDuration)
                let latestStart = max(0, sourceDuration - minimumDuration)
                updated.sourceStart = min(max(0, sourceStart ?? updated.sourceStart), latestStart)
                let availableDuration = max(minimumDuration, sourceDuration - updated.sourceStart)
                updated.duration = min(max(minimumDuration, requestedSourceDuration ?? updated.duration), availableDuration)
            } else {
                if let sourceStart { updated.sourceStart = max(0, sourceStart) }
                if let requestedSourceDuration { updated.duration = requestedSourceDuration }
            }
        }
        if let gain { updated.gain = gain }
        if let fadeIn { updated.fadeIn = fadeIn }
        if let fadeOut { updated.fadeOut = fadeOut }
        if let pitchSemitones { updated.pitchSemitones = min(12, max(-12, pitchSemitones)) }
        guard updated != track.clips[index] else { return }
        cancelActiveStemSeparations(forClipID: clip.id)
        registerEdit()
        track.clips[index] = updated
        objectWillChange.send()
    }

    /// Estimates a missing source BPM, applies the project tempo, and enables
    /// automatic follow when the project BPM changes later.
    func syncClipTempo(clipId: UUID, sourceBPM overrideBPM: Double? = nil) throws {
        guard let (track, clip) = findClip(clipId),
              let index = track.clips.firstIndex(where: { $0.id == clipId }) else {
            throw NSError(domain: "Remixa", code: 50, userInfo: [NSLocalizedDescriptionKey: "クリップが見つかりません"])
        }
        let sourceBPM: Double
        if let overrideBPM {
            guard overrideBPM.isFinite, overrideBPM > 0 else {
                throw NSError(domain: "Remixa", code: 51, userInfo: [NSLocalizedDescriptionKey: "元BPMは0より大きい数値を入力してください"])
            }
            sourceBPM = overrideBPM
        } else if let existing = clip.sourceBPM {
            sourceBPM = existing
        } else if let estimate = BPMEstimator.estimate(fileURL: sourceURL(for: clip)) {
            sourceBPM = estimate
        } else {
            throw NSError(domain: "Remixa", code: 51, userInfo: [NSLocalizedDescriptionKey: "元BPMを推定できませんでした。元BPMを入力してください"])
        }
        guard let rate = Self.tempoRate(projectBPM: bpm, sourceBPM: sourceBPM) else {
            throw NSError(domain: "Remixa", code: 52, userInfo: [NSLocalizedDescriptionKey: "プロジェクトBPMまたは元BPMが不正です"])
        }
        var updated = track.clips[index]
        updated.sourceBPM = sourceBPM
        updated.tempoRate = rate
        updated.syncToProject = true
        guard updated != track.clips[index] else { return }
        cancelActiveStemSeparations(forClipID: clipId)
        registerEdit()
        track.clips[index] = updated
        objectWillChange.send()
    }

    private static func tempoRate(projectBPM: Double, sourceBPM: Double) -> Double? {
        guard projectBPM.isFinite, projectBPM > 0, sourceBPM.isFinite, sourceBPM > 0 else { return nil }
        let rawRate = projectBPM / sourceBPM
        guard rawRate.isFinite, rawRate > 0 else { return nil }
        var candidates: [Double] = []
        var candidate = rawRate
        while candidate >= 0.5 {
            if candidate <= 2.0 { candidates.append(candidate) }
            candidate /= 2
        }
        candidate = rawRate * 2
        while candidate.isFinite, candidate <= 2.0 {
            if candidate >= 0.5 { candidates.append(candidate) }
            candidate *= 2
        }
        guard let closest = candidates.min(by: { abs($0 - 1.0) < abs($1 - 1.0) }) else { return nil }
        return min(2.0, max(0.5, closest))
    }

    func splitClip(_ clip: Clip, on track: Track, at playhead: Double) {
        guard let index = track.clips.firstIndex(where: { $0.id == clip.id }),
              playhead > clip.timelineStart, playhead < clip.timelineEnd else { return }
        cancelActiveStemSeparations(forClipID: clip.id)
        pushUndo()
        let offset = min(clip.duration, max(0, playhead - clip.timelineStart) * clip.tempoRate)
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
        copy.timelineStart = max(0, snapped(clip.timelineEnd))
        track.clips.append(copy)
        objectWillChange.send()
    }

    func deleteClip(_ clip: Clip, on track: Track) {
        cancelActiveStemSeparations(forClipID: clip.id)
        pushUndo()
        track.clips.removeAll { $0.id == clip.id }
        selectedClipIDs.remove(clip.id)
    }

    /// Replaces a clip's audio wholesale (used when the v0.1 clip editor commits an edit).
    func replaceClipAudio(_ clip: Clip, on track: Track, newBuffer: AVAudioPCMBuffer, cacheKey: String) {
        guard let index = track.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        let safeName = cacheKey.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? String($0) : "-"
        }.joined()
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remixa-\(safeName)-\(UUID().uuidString).caf")
        do {
            let audioFile = try AVAudioFile(
                forWriting: sourceURL,
                settings: newBuffer.format.settings,
                commonFormat: newBuffer.format.commonFormat,
                interleaved: newBuffer.format.isInterleaved
            )
            try audioFile.write(from: newBuffer)
        } catch {
            errorMessage = "編集した音声を保存できませんでした: \(error.localizedDescription)"
            return
        }
        cancelActiveStemSeparations(forClipID: clip.id)
        pushUndo()
        var updated = track.clips[index]
        updated.audioPath = sourceURL.path
        updated.isRelative = false
        updated.sourceStart = 0
        updated.duration = Double(newBuffer.frameLength) / newBuffer.format.sampleRate
        track.clips[index] = updated
        objectWillChange.send()
    }

    private func snapped(_ seconds: Double) -> Double {
        guard snapDivision != .off, bpm > 0 else { return seconds }
        let beat = 60.0 / bpm
        let interval: Double
        switch snapDivision {
        case .quarterBeat: interval = beat / 4
        case .halfBeat: interval = beat / 2
        case .beat: interval = beat
        case .bar: interval = beat * Double(beatsPerBar)
        case .off: return seconds
        }
        return (seconds / interval).rounded() * interval
    }

    // MARK: - Audio loading

    func sourceURL(for clip: Clip) -> URL {
        clip.resolvedURL(packageAudioDir: fileURL?.appendingPathComponent("Audio"))
    }

    func sourceDuration(for clip: Clip) -> Double? {
        try? AudioFileRegionReader.duration(of: sourceURL(for: clip))
    }

    /// Returns a processed, clip-sized buffer using a bounded LRU cache. Source reads
    /// are limited to the clip's trim region, so normal timeline playback does not
    /// decode or retain the rest of a long source file.
    func processedBuffer(for clip: Clip) -> AVAudioPCMBuffer? {
        let url = sourceURL(for: clip)
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let key = ProcessedBufferKey(
            path: url.path,
            fileSize: (attributes[.size] as? NSNumber)?.intValue ?? 0,
            modificationTime: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            sourceStart: clip.sourceStart.bitPattern,
            duration: clip.duration.bitPattern,
            tempoRate: clip.tempoRate.bitPattern,
            pitchSemitones: clip.pitchSemitones,
            gain: clip.gain.bitPattern,
            fadeIn: clip.fadeIn.bitPattern,
            fadeOut: clip.fadeOut.bitPattern
        )
        if var entry = processedBufferCache[key] {
            processedBufferCacheClock &+= 1
            entry.lastAccess = processedBufferCacheClock
            processedBufferCache[key] = entry
            return entry.buffer
        }

        guard let sourceRegion = try? AudioFileRegionReader.read(
            url: url, sourceStart: clip.sourceStart, duration: clip.duration
        ), let processed = TimelineEngine.processedBuffer(for: clip, sourceRegion: sourceRegion) else {
            return nil
        }
        let bytes = Int(min(
            Int64(Int.max),
            Int64(processed.frameLength) * Int64(processed.format.channelCount) * Int64(MemoryLayout<Float>.size)
        ))
        guard bytes <= processedBufferCacheLimit else { return processed }

        while processedBufferCacheBytes + bytes > processedBufferCacheLimit,
              let oldestKey = processedBufferCache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key,
              let oldest = processedBufferCache.removeValue(forKey: oldestKey) {
            processedBufferCacheBytes -= oldest.byteCount
        }
        processedBufferCacheClock &+= 1
        processedBufferCache[key] = ProcessedBufferEntry(buffer: processed, byteCount: bytes, lastAccess: processedBufferCacheClock)
        processedBufferCacheBytes += bytes
        return processed
    }

    func invalidateAudioCaches() {
        waveformCache.removeAll(keepingCapacity: false)
        processedBufferCache.removeAll(keepingCapacity: false)
        processedBufferCacheBytes = 0
        processedBufferCacheClock = 0
    }

    /// Downsampled peaks for the clip's whole source file (not just the trimmed
    /// region), cached by resolved file path so multiple clips sharing a source
    /// (or repeated redraws of the same clip) don't re-decode/re-downsample.
    func waveform(for clip: Clip) -> CachedWaveform? {
        let url = sourceURL(for: clip)
        let key = url.path
        if let cached = waveformCache[key] { return cached }
        guard let waveform = try? WaveformGenerator.peaks(from: url, targetCount: 800) else { return nil }
        let result = CachedWaveform(peaks: waveform.peaks, sourceDuration: waveform.duration)
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
        let sessionID = projectSessionID
        let runID = UUID()
        let cancellation = StemSeparationService.CancellationToken()
        activeStemRuns[runID] = ActiveStemRun(sessionID: sessionID, trackID: track.id, clipID: clip.id, cancellation: cancellation)
        var outputDirForCleanup: URL?
        var keepOutput = false
        defer {
            activeStemRuns.removeValue(forKey: runID)
            if !keepOutput, let outputDirForCleanup {
                try? FileManager.default.removeItem(at: outputDirForCleanup)
            }
        }

        let sourceURL = sourceURL(for: clip)
        guard let sourceBuffer = try? AudioFileRegionReader.read(
            url: sourceURL, sourceStart: clip.sourceStart, duration: clip.duration
        ) else {
            throw NSError(domain: "Remixa", code: 41, userInfo: [NSLocalizedDescriptionKey: "音声を読み込めませんでした"])
        }

        // Render just the clip's trimmed region to a temp wav for Demucs to consume.
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("remixa-stem-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let regionURL = tmpDir.appendingPathComponent("region.wav")
        try Self.writeRegion(of: sourceBuffer, sourceStart: 0, duration: clip.duration, to: regionURL)

        let outputDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Remixa", isDirectory: true)
            .appendingPathComponent("stems-output", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
        outputDirForCleanup = outputDir

        let stems = try await StemSeparationService.shared.separate(
            audioURL: regionURL,
            outputDir: outputDir,
            cancellation: cancellation,
            progress: progress
        )
        try Task.checkCancellation()
        guard activeStemRuns[runID]?.sessionID == sessionID,
              sessionID == projectSessionID,
              let currentTrack = tracks.first(where: { $0.id == track.id }),
              let currentClip = currentTrack.clips.first(where: { $0.id == clip.id }),
              currentClip == clip else {
            throw StemSeparationService.StemError.cancelled
        }

        var preparedTracks: [Track] = []
        var newTrackIDs: [UUID] = []
        for stem in stems {
            guard let duration = try? AudioFileRegionReader.duration(of: stem.url) else { continue }
            let newTrack = Track(name: Self.japaneseStemName(for: stem.name))
            let newClip = Clip(name: newTrack.name, audioURL: stem.url, timelineStart: clip.timelineStart, sourceStart: 0, duration: duration)
            newTrack.clips.append(newClip)
            preparedTracks.append(newTrack)
            newTrackIDs.append(newTrack.id)
        }
        guard !preparedTracks.isEmpty else {
            throw NSError(domain: "Remixa", code: 43, userInfo: [NSLocalizedDescriptionKey: "パート分離の音声を読み込めませんでした"])
        }
        pushUndo()
        tracks.append(contentsOf: preparedTracks)
        currentTrack.mute = true
        objectWillChange.send()
        keepOutput = true
        return newTrackIDs
    }

    private func cancelActiveStemSeparations(forClipID clipID: UUID? = nil, forTrackID trackID: UUID? = nil) {
        for run in activeStemRuns.values where (clipID == nil || run.clipID == clipID) && (trackID == nil || run.trackID == trackID) {
            run.cancellation.cancel()
        }
    }

    private func cancelAllActiveStemSeparations() {
        projectSessionID = UUID()
        for run in activeStemRuns.values {
            run.cancellation.cancel()
        }
        activeStemRuns.removeAll()
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

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        if startFrame == 0, clampedCount == buffer.frameLength {
            try file.write(from: buffer)
            return
        }
        guard let region = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(clampedCount, 1)) else {
            throw NSError(domain: "Remixa", code: 42, userInfo: [NSLocalizedDescriptionKey: "バッファを確保できませんでした"])
        }
        region.frameLength = clampedCount
        if clampedCount > 0, let srcData = buffer.floatChannelData, let dstData = region.floatChannelData {
            for ch in 0..<Int(format.channelCount) {
                dstData[ch].update(from: srcData[ch] + Int(startFrame), count: Int(clampedCount))
            }
        }
        try file.write(from: region)
    }

    func resetForNewProject() {
        cancelAllActiveStemSeparations()
        tracks = [Track(name: "トラック 1")]
        bpm = 120
        masterVolume = 1.0
        loopRegion = nil
        selectedClipID = nil
        markers = []
        snapDivision = .beat
        timeSignature = .fourFour
        playbackMetronomeEnabled = false
        exportMetronomeEnabled = false
        metronomeVolume = 0.4
        countInEnabled = false
        projectKey = nil
        selectedClipIDs = []
        fileURL = nil
        isDirty = false
        invalidateAudioCaches()
        errorMessage = nil
        clearUndoHistory()
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
