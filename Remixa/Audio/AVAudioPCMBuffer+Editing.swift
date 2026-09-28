import AVFoundation

extension AVAudioPCMBuffer {
    /// Deep-copies this buffer (frame data included).
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        copy.frameLength = frameLength
        let channelCount = Int(format.channelCount)
        if let src = floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channelCount {
                dst[ch].update(from: src[ch], count: Int(frameLength))
            }
        }
        return copy
    }

    /// Returns a new buffer containing only [start, end) frames.
    func slice(from start: AVAudioFramePosition, to end: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        let clampedStart = max(0, min(start, AVAudioFramePosition(frameLength)))
        let clampedEnd = max(clampedStart, min(end, AVAudioFramePosition(frameLength)))
        let length = AVAudioFrameCount(clampedEnd - clampedStart)
        guard length > 0, let newBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length) else { return nil }
        newBuffer.frameLength = length
        let channelCount = Int(format.channelCount)
        if let src = floatChannelData, let dst = newBuffer.floatChannelData {
            for ch in 0..<channelCount {
                dst[ch].update(from: src[ch] + Int(clampedStart), count: Int(length))
            }
        }
        return newBuffer
    }

    /// Returns a new buffer with [start, end) removed (cut).
    func removingRange(from start: AVAudioFramePosition, to end: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        let clampedStart = max(0, min(start, AVAudioFramePosition(frameLength)))
        let clampedEnd = max(clampedStart, min(end, AVAudioFramePosition(frameLength)))
        let removedLength = Int(clampedEnd - clampedStart)
        let newLength = Int(frameLength) - removedLength
        guard newLength >= 0, let newBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(newLength, 1))) else { return nil }
        newBuffer.frameLength = AVAudioFrameCount(newLength)
        let channelCount = Int(format.channelCount)
        if let src = floatChannelData, let dst = newBuffer.floatChannelData {
            for ch in 0..<channelCount {
                // copy [0, start)
                if clampedStart > 0 {
                    dst[ch].update(from: src[ch], count: Int(clampedStart))
                }
                // copy [end, frameLength) after start
                let tailCount = Int(frameLength) - Int(clampedEnd)
                if tailCount > 0 {
                    (dst[ch] + Int(clampedStart)).update(from: src[ch] + Int(clampedEnd), count: tailCount)
                }
            }
        }
        return newBuffer
    }

    /// Applies a linear fade in-place over [start, end).
    func applyFade(from start: AVAudioFramePosition, to end: AVAudioFramePosition, fadeIn: Bool) {
        let clampedStart = max(0, min(start, AVAudioFramePosition(frameLength)))
        let clampedEnd = max(clampedStart, min(end, AVAudioFramePosition(frameLength)))
        let count = Int(clampedEnd - clampedStart)
        guard count > 0, let data = floatChannelData else { return }
        let channelCount = Int(format.channelCount)
        for ch in 0..<channelCount {
            for i in 0..<count {
                let progress = Float(i) / Float(max(count - 1, 1))
                let gain = fadeIn ? progress : (1.0 - progress)
                data[ch][Int(clampedStart) + i] *= gain
            }
        }
    }
}
