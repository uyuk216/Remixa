import AVFoundation

/// Very simple BPM auto-estimate based on energy-envelope autocorrelation.
/// Not intended to be precise — just a helpful starting hint for the user.
enum BPMEstimator {
    static func estimate(buffer: AVAudioPCMBuffer) -> Double? {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let sampleRate = buffer.format.sampleRate
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        // Build a mono envelope, downsampled to ~200Hz for speed.
        let envelopeRate = 200.0
        let hop = max(1, Int(sampleRate / envelopeRate))
        var envelope: [Float] = []
        envelope.reserveCapacity(frameCount / hop + 1)
        var i = 0
        while i < frameCount {
            let end = min(i + hop, frameCount)
            var sum: Float = 0
            var n = 0
            for ch in 0..<channelCount {
                for j in i..<end {
                    sum += abs(data[ch][j])
                    n += 1
                }
            }
            envelope.append(n > 0 ? sum / Float(n) : 0)
            i = end
        }
        guard envelope.count > 20 else { return nil }

        // Difference (onset emphasis)
        var diff = [Float](repeating: 0, count: envelope.count)
        for k in 1..<envelope.count {
            diff[k] = max(0, envelope[k] - envelope[k - 1])
        }

        // Autocorrelation over plausible BPM range (60...200 BPM)
        let minBPM = 60.0, maxBPM = 200.0
        let minLag = Int(envelopeRate * 60.0 / maxBPM)
        let maxLag = Int(envelopeRate * 60.0 / minBPM)
        guard maxLag < diff.count, minLag < maxLag else { return nil }

        var bestLag = minLag
        var bestScore: Float = -.infinity
        for lag in minLag...maxLag {
            var score: Float = 0
            for k in 0..<(diff.count - lag) {
                score += diff[k] * diff[k + lag]
            }
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        guard bestLag > 0 else { return nil }
        let bpm = 60.0 * envelopeRate / Double(bestLag)
        return (bpm * 10).rounded() / 10
    }
}
