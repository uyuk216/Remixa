import Foundation
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
enum ProjectDocumentIO {
    private static let projectFileName = "project.json"
    private static let audioDirName = "Audio"

    @MainActor
    static func save(_ project: RemixaProject, to url: URL) throws {
        let fm = FileManager.default
        let parentURL = url.deletingLastPathComponent()
        try fm.createDirectory(at: parentURL, withIntermediateDirectories: true)

        let stagingURL = parentURL.appendingPathComponent(".\(url.lastPathComponent).staging-\(UUID().uuidString)", isDirectory: true)
        let backupURL = parentURL.appendingPathComponent(".\(url.lastPathComponent).backup-\(UUID().uuidString)", isDirectory: true)
        var backupContainsOldPackage = false
        var installed = false
        defer {
            try? fm.removeItem(at: stagingURL)
            if !installed, backupContainsOldPackage, !fm.fileExists(atPath: url.path) {
                try? fm.moveItem(at: backupURL, to: url)
            }
        }

        let stagingAudioDir = stagingURL.appendingPathComponent(audioDirName, isDirectory: true)
        try fm.createDirectory(at: stagingAudioDir, withIntermediateDirectories: true)

        var relativeNameForSource: [String: String] = [:]
        var usedNameKeys = Set<String>()
        var updatedClipsByTrackID: [UUID: [Clip]] = [:]

        func sourceURL(for clip: Clip) throws -> URL {
            let source: URL
            if clip.isRelative {
                guard let projectURL = project.fileURL else {
                    throw NSError(domain: "Remixa", code: 21, userInfo: [NSLocalizedDescriptionKey: "音声ファイルの保存元を特定できません"])
                }
                source = projectURL.appendingPathComponent(audioDirName, isDirectory: true)
                    .appendingPathComponent(clip.audioPath)
            } else {
                source = URL(fileURLWithPath: clip.audioPath)
            }
            let normalized = source.standardizedFileURL
            guard FileManager.default.fileExists(atPath: normalized.path) else {
                throw NSError(domain: "Remixa", code: 22, userInfo: [NSLocalizedDescriptionKey: "音声ファイルが見つかりません: \(source.lastPathComponent)"])
            }
            return normalized
        }

        func collisionKey(for name: String) -> String {
            name.precomposedStringWithCanonicalMapping
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }

        func relativeName(for source: URL) throws -> String {
            if let existing = relativeNameForSource[source.path] { return existing }

            let originalName = source.lastPathComponent
            let sourceStem = source.deletingPathExtension().lastPathComponent
            let fileExtension = source.pathExtension
            var candidate = originalName
            var suffix = 1
            while usedNameKeys.contains(collisionKey(for: candidate)) || FileManager.default.fileExists(atPath: stagingAudioDir.appendingPathComponent(candidate).path) {
                let stemWithSuffix = "\(sourceStem)_\(suffix)"
                candidate = fileExtension.isEmpty ? stemWithSuffix : "\(stemWithSuffix).\(fileExtension)"
                suffix += 1
            }

            try FileManager.default.copyItem(at: source, to: stagingAudioDir.appendingPathComponent(candidate))
            relativeNameForSource[source.path] = candidate
            usedNameKeys.insert(collisionKey(for: candidate))
            return candidate
        }

        var snapshotTracks: [ProjectSnapshot.TrackSnapshot] = []
        for track in project.tracks {
            var updatedClips: [Clip] = []
            updatedClips.reserveCapacity(track.clips.count)
            for clip in track.clips {
                let source = try sourceURL(for: clip)
                let name = try relativeName(for: source)
                var updated = clip
                updated.audioPath = name
                updated.isRelative = true
                updatedClips.append(updated)
            }
            updatedClipsByTrackID[track.id] = updatedClips
            snapshotTracks.append(
                ProjectSnapshot.TrackSnapshot(
                    id: track.id, name: track.name, clips: updatedClips,
                    colorIndex: track.colorIndex,
                    volume: track.volume, pan: track.pan, mute: track.mute, solo: track.solo,
                    effects: EffectsRackSettingsCodable(settings: track.effects),
                    automation: track.automation
                )
            )
        }

        let snapshot = ProjectSnapshot(
            bpm: project.bpm,
            masterVolume: project.masterVolume,
            tracks: snapshotTracks,
            markers: project.markers,
            snapDivision: project.snapDivision,
            timeSignature: project.timeSignature,
            playbackMetronomeEnabled: project.playbackMetronomeEnabled,
            exportMetronomeEnabled: project.exportMetronomeEnabled,
            metronomeVolume: project.metronomeVolume,
            countInEnabled: project.countInEnabled,
            projectKey: project.projectKey
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: stagingURL.appendingPathComponent(projectFileName), options: .atomic)

        if fm.fileExists(atPath: url.path) {
            try fm.moveItem(at: url, to: backupURL)
            backupContainsOldPackage = true
        }
        do {
            try fm.moveItem(at: stagingURL, to: url)
            installed = true
        } catch {
            if backupContainsOldPackage {
                do {
                    try fm.moveItem(at: backupURL, to: url)
                    backupContainsOldPackage = false
                } catch {
                    throw NSError(domain: "Remixa", code: 23, userInfo: [
                        NSLocalizedDescriptionKey: "新しいプロジェクトを配置できず、元のプロジェクトも復元できませんでした: \(error.localizedDescription)"
                    ])
                }
            }
            throw error
        }

        if backupContainsOldPackage {
            try? fm.removeItem(at: backupURL)
            backupContainsOldPackage = false
        }

        for track in project.tracks {
            track.clips = updatedClipsByTrackID[track.id] ?? track.clips
        }
        project.fileURL = url
        project.invalidateAudioCaches()
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
        project.markers = snapshot.markers
        project.snapDivision = snapshot.snapDivision
        project.timeSignature = snapshot.timeSignature
        project.playbackMetronomeEnabled = snapshot.playbackMetronomeEnabled
        project.exportMetronomeEnabled = snapshot.exportMetronomeEnabled
        project.metronomeVolume = snapshot.metronomeVolume
        project.countInEnabled = snapshot.countInEnabled
        project.projectKey = snapshot.projectKey
        project.tracks = snapshot.tracks.map { ts in
            let t = Track(id: ts.id, name: ts.name, clips: ts.clips)
            t.volume = ts.volume; t.pan = ts.pan; t.mute = ts.mute; t.solo = ts.solo
            t.effects = ts.effects.settings
            t.automation = ts.automation
            return t
        }
        project.fileURL = url
        project.isDirty = false
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return project
    }
}
