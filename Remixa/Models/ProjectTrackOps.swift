import Foundation

extension RemixaProject {
    /// Moves a track to a new index (undoable).
    func moveTrack(_ track: Track, toIndex newIndex: Int) {
        guard let from = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        let target = max(0, min(tracks.count - 1, newIndex))
        guard target != from else { return }
        pushUndo()
        let item = tracks.remove(at: from)
        tracks.insert(item, at: target)
    }

    /// Moves `track` to the position currently occupied by `other` (drag reorder).
    func moveTrack(_ track: Track, onto other: Track) {
        guard let to = tracks.firstIndex(where: { $0.id == other.id }) else { return }
        moveTrack(track, toIndex: to)
    }

    func moveTrack(_ track: Track, by offset: Int) {
        guard let from = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        moveTrack(track, toIndex: from + offset)
    }

    /// Inserts a copy of the track (clips get fresh IDs) right below the original.
    func duplicateTrack(_ track: Track) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        pushUndo()
        let copy = track.copy()
        let clone = Track(name: track.name + " のコピー", clips: copy.clips.map { clip in
            var c = clip
            c.id = UUID()
            return c
        }, colorIndex: track.colorIndex)
        clone.volume = track.volume
        clone.pan = track.pan
        clone.mute = track.mute
        clone.solo = false
        clone.effects = track.effects
        clone.automation = track.automation
        tracks.insert(clone, at: index + 1)
    }
}
