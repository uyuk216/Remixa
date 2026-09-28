import Foundation
import AVFoundation
import UniformTypeIdentifiers
import AppKit

extension UTType {
    /// `.remixa` project package. Declared in Info.plist as UTExportedTypeDeclarations
    /// with `public.package` conformance so Finder treats it as a single document.
    static var remixaProject: UTType {
        UTType(exportedAs: "io.github.uyuk216.remixa.project")
    }
}

/// Reads and writes the `.remixa` project package:
///
///   MyMix.remixa/
///     project.json   — ProjectSnapshot (bpm, tracks, clips, effects, mix state)
///     Audio/          — copies of every source file referenced by a clip
///
/// A plain-directory package (not `FileWrapper`-atomic) is used to keep this simple
/// for v0.2; see README for the tradeoff.
enum ProjectDocumentIO {
    private static let projectFileName = "project.json"
    private static let audioDirName = "Audio"

    @MainActor
    static func save(_ project: RemixaProject, to url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let audioDir = url.appendingPathComponent(audioDirName)
        if !fm.fileExists(atPath: audioDir.path) {
            try fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
        }

        var pathForAbsoluteSource: [String: String] = [:] // absolute path -> relative audio filename
        var usedNames = Set<String>()

        func relativeName(for absolutePath: String) throws -> String {
            if let existing = pathForAbsoluteSource[absolutePath] { return existing }
            let source = URL(fileURLWithPath: absolutePath)
            var candidate = source.lastPathComponent
            var suffix = 1
            while usedNames.contains(candidate) {
                candidate = source.deletingPathExtension().lastPathComponent + "_\(suffix)." + source.pathExtension
                suffix += 1
            }
            usedNames.insert(candidate)
            let destination = audioDir.appendingPathComponent(candidate)
            if !fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
                try fm.copyItem(at: source, to: destination)
            }
            pathForAbsoluteSource[absolutePath] = candidate
            return candidate
        }

        var snapshotTracks: [ProjectSnapshot.TrackSnapshot] = []
        for track in project.tracks {
            var newClips: [Clip] = []
            for clip in track.clips {
                var updated = clip
                if !clip.isRelative {
                    let name = try relativeName(for: clip.audioPath)
                    updated.audioPath = name
                    updated.isRelative = true
                    // Re-key the in-memory buffer cache to the new relative name so
                    // playback keeps working without a reload.
                    if let buffer = project.bufferCache[clip.audioPath] {
                        project.bufferCache[audioDir.appendingPathComponent(name).path] = buffer
                    }
                }
                newClips.append(updated)
            }
            track.clips = newClips
            snapshotTracks.append(
                ProjectSnapshot.TrackSnapshot(
                    id: track.id, name: track.name, clips: newClips,
                    volume: track.volume, pan: track.pan, mute: track.mute, solo: track.solo,
                    effects: EffectsRackSettingsCodable(settings: track.effects)
                )
            )
        }

        let snapshot = ProjectSnapshot(bpm: project.bpm, masterVolume: project.masterVolume, tracks: snapshotTracks)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url.appendingPathComponent(projectFileName), options: .atomic)

        project.fileURL = url
        project.isDirty = false
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    @MainActor
    static func load(from url: URL) throws -> RemixaProject {
        let fm = FileManager.default
        let projectFile = url.appendingPathComponent(projectFileName)
        guard fm.fileExists(atPath: projectFile.path) else {
            throw NSError(domain: "Remixa", code: 20, userInfo: [NSLocalizedDescriptionKey: "プロジェクトファイルが見つかりません"])
        }
        let data = try Data(contentsOf: projectFile)
        let snapshot = try JSONDecoder().decode(ProjectSnapshot.self, from: data)

        let project = RemixaProject()
        project.bpm = snapshot.bpm
        project.masterVolume = snapshot.masterVolume
        project.tracks = snapshot.tracks.map { ts in
            let t = Track(id: ts.id, name: ts.name, clips: ts.clips)
            t.volume = ts.volume; t.pan = ts.pan; t.mute = ts.mute; t.solo = ts.solo
            t.effects = ts.effects.settings
            return t
        }
        project.fileURL = url
        project.isDirty = false
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return project
    }
}
