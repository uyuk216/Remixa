import Foundation
import AVFoundation
import SwiftUI

/// Central document model for the currently loaded audio.
/// Kept modular so v0.2 (multitrack) can later hold an array of these,
/// and v0.3 (stem separation) can add derived buffers without touching the edit/undo core.
@MainActor
final class AudioDocument: ObservableObject {
    @Published var buffer: AVAudioPCMBuffer?
    @Published var fileURL: URL?
    @Published var sampleRate: Double = 44100
    @Published var selection: ClosedRange<Double>?  // seconds
    @Published var estimatedBPM: Double?
    @Published var waveformPeaks: [Float] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // Effects & playback parameters (persist across edits; applied live by AudioEngineController)
    @Published var effects = EffectsRackSettings()
    @Published var tempoPercent: Double = 100.0   // 50...200
    @Published var pitchSemitones: Double = 0.0   // -12...12
    @Published var loopEnabled: Bool = false

    private var undoStack: [AVAudioPCMBuffer] = []
    private var redoStack: [AVAudioPCMBuffer] = []

    var duration: Double {
        guard let buffer, sampleRate > 0 else { return 0 }
        return Double(buffer.frameLength) / sampleRate
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func load(url: URL) {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let file = try AVAudioFile(forReading: url)
                let format = file.processingFormat
                guard let newBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
                    throw NSError(domain: "Remixa", code: 1, userInfo: [NSLocalizedDescriptionKey: "バッファを確保できませんでした"])
                }
                try file.read(into: newBuffer)
                await MainActor.run {
                    self.buffer = newBuffer
                    self.fileURL = url
                    self.sampleRate = format.sampleRate
                    self.selection = nil
                    self.undoStack.removeAll()
                    self.redoStack.removeAll()
                    self.isLoading = false
                    self.waveformPeaks = WaveformGenerator.peaks(from: newBuffer, targetCount: 2000)
                    self.estimatedBPM = BPMEstimator.estimate(buffer: newBuffer)
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = "読み込みに失敗しました: \(error.localizedDescription)"
                }
            }
        }
    }

    private func pushUndo() {
        guard let buffer else { return }
        if let copy = buffer.deepCopy() {
            undoStack.append(copy)
            if undoStack.count > 50 { undoStack.removeFirst() }
        }
        redoStack.removeAll()
    }

    func undo() {
        guard let current = buffer, let previous = undoStack.popLast() else { return }
        if let copy = current.deepCopy() {
            redoStack.append(copy)
        }
        buffer = previous
        refreshDerived()
    }

    func redo() {
        guard let current = buffer, let next = redoStack.popLast() else { return }
        if let copy = current.deepCopy() {
            undoStack.append(copy)
        }
        buffer = next
        refreshDerived()
    }

    private func refreshDerived() {
        guard let buffer else { return }
        waveformPeaks = WaveformGenerator.peaks(from: buffer, targetCount: 2000)
        if selection != nil {
            let dur = duration
            if let sel = selection, sel.lowerBound >= dur {
                selection = nil
            }
        }
    }

    // MARK: - Editing operations

    func trimToSelection() {
        guard let buffer, let selection else { return }
        let start = frame(for: selection.lowerBound)
        let end = frame(for: selection.upperBound)
        guard end > start, let newBuffer = buffer.slice(from: start, to: end) else { return }
        pushUndo()
        self.buffer = newBuffer
        self.selection = nil
        refreshDerived()
    }

    func deleteSelection() {
        guard let buffer, let selection else { return }
        let start = frame(for: selection.lowerBound)
        let end = frame(for: selection.upperBound)
        guard end > start, let newBuffer = buffer.removingRange(from: start, to: end) else { return }
        pushUndo()
        self.buffer = newBuffer
        self.selection = nil
        refreshDerived()
    }

    func fadeSelection(fadeIn: Bool) {
        guard let buffer, let selection else { return }
        let start = frame(for: selection.lowerBound)
        let end = frame(for: selection.upperBound)
        guard end > start else { return }
        pushUndo()
        buffer.applyFade(from: start, to: end, fadeIn: fadeIn)
        // trigger publish
        self.buffer = buffer
        refreshDerived()
    }

    private func frame(for seconds: Double) -> AVAudioFramePosition {
        AVAudioFramePosition(seconds * sampleRate)
    }
}
