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

        return estimate(envelope: envelope, envelopeRate: envelopeRate)
    }

    /// Builds the same low-rate envelope directly from the file so tempo sync does not
    /// force a full-length PCM buffer into the project's source cache.
    static func estimate(fileURL: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32768) else { return nil }

        let envelopeRate = 200.0
        let hop = max(1, Int(format.sampleRate / envelopeRate))
        let channelCount = Int(format.channelCount)
        var envelope: [Float] = []
        envelope.reserveCapacity(Int(file.length) / hop + 1)
        var hopFrames = 0
        var hopSum: Float = 0
        var hopSamples = 0

        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let request = AVAudioFrameCount(min(32768, remaining))
            guard (try? file.read(into: buffer, frameCount: request)) != nil,
                  let data = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            for frame in 0..<Int(buffer.frameLength) {
                for channel in 0..<channelCount {
                    hopSum += abs(data[channel][frame])
                    hopSamples += 1
                }
                hopFrames += 1
                if hopFrames == hop {
                    envelope.append(hopSamples > 0 ? hopSum / Float(hopSamples) : 0)
                    hopFrames = 0
                    hopSum = 0
                    hopSamples = 0
                }
            }
        }
        if hopFrames > 0 {
            envelope.append(hopSamples > 0 ? hopSum / Float(hopSamples) : 0)
        }
        return estimate(envelope: envelope, envelopeRate: envelopeRate)
    }

    private static func estimate(envelope: [Float], envelopeRate: Double) -> Double? {
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
