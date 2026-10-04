import AVFoundation

/// Lightweight chroma estimator based on Goertzel energies and Krumhansl key profiles.
/// It returns a small Sendable value so callers can keep audio decoding off the main actor.
enum KeyDetector {
    private static let majorProfile = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    static func estimate(fileURL: URL, sourceStart: Double, duration: Double) -> MusicalKey? {
        guard sourceStart.isFinite, duration.isFinite, duration > 0,
              let file = try? AVAudioFile(forReading: fileURL, commonFormat: .pcmFormatFloat32, interleaved: false),
              file.processingFormat.sampleRate > 0 else { return nil }

        let sampleRate = file.processingFormat.sampleRate
        let start = min(file.length, max(0, AVAudioFramePosition(sourceStart * sampleRate)))
        let maximumFrames = AVAudioFramePosition(min(duration, 30) * sampleRate)
        let available = max(0, min(maximumFrames, file.length - start))
        guard available > 0 else { return nil }
        file.framePosition = start

        let windowSize = 4096
        let readSize: AVAudioFrameCount = 8192
        var chroma = Array(repeating: 0.0, count: 12)
        var remaining = available
        while remaining > 0 {
            let count = AVAudioFrameCount(min(AVAudioFramePosition(readSize), remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count),
                  (try? file.read(into: buffer, frameCount: count)) != nil,
                  let channels = buffer.floatChannelData else { return nil }
            let frames = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard frames >= windowSize else { break }

            var offset = 0
            while offset + windowSize <= frames {
                var mono = Array(repeating: 0.0, count: windowSize)
                for frame in 0..<windowSize {
                    var sample = 0.0
                    for channel in 0..<channelCount { sample += Double(channels[channel][offset + frame]) }
                    let window = 0.5 - 0.5 * cos(2 * .pi * Double(frame) / Double(windowSize - 1))
                    mono[frame] = sample / Double(channelCount) * window
                }
                for midi in 36...84 {
                    let frequency = 440 * pow(2, Double(midi - 69) / 12)
                    let energy = goertzelEnergy(mono, sampleRate: sampleRate, frequency: frequency)
                    chroma[midi % 12] += energy
                }
                offset += windowSize
            }
            remaining -= AVAudioFramePosition(buffer.frameLength)
            if buffer.frameLength == 0 { break }
        }

        guard chroma.contains(where: { $0 > 0 }), chroma.allSatisfy(\.isFinite) else { return nil }
        let centered = chroma.map { $0 - chroma.reduce(0, +) / 12 }
        var bestKey: MusicalKey?
        var bestScore = -Double.infinity
        for tonic in 0..<12 {
            for (mode, profile) in [(KeyMode.major, majorProfile), (.minor, minorProfile)] {
                let rotated = (0..<12).map { profile[($0 - tonic + 12) % 12] }
                let score = correlation(centered, rotated)
                if score > bestScore {
                    bestScore = score
                    bestKey = MusicalKey(tonic: tonic, mode: mode)
                }
            }
        }
        return bestKey
    }

    private static func goertzelEnergy(_ samples: [Double], sampleRate: Double, frequency: Double) -> Double {
        let omega = 2 * .pi * frequency / sampleRate
        let coefficient = 2 * cos(omega)
        var previous = 0.0
        var previousPrevious = 0.0
        for sample in samples {
            let current = sample + coefficient * previous - previousPrevious
            previousPrevious = previous
            previous = current
        }
        return max(0, previous * previous + previousPrevious * previousPrevious - coefficient * previous * previousPrevious)
    }

    private static func correlation(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let lhsMean = lhs.reduce(0, +) / Double(lhs.count)
        let rhsMean = rhs.reduce(0, +) / Double(rhs.count)
        var numerator = 0.0
        var lhsPower = 0.0
        var rhsPower = 0.0
        for index in lhs.indices {
            let x = lhs[index] - lhsMean
            let y = rhs[index] - rhsMean
            numerator += x * y
            lhsPower += x * x
            rhsPower += y * y
        }
        let denominator = sqrt(lhsPower * rhsPower)
        return denominator > 0 ? numerator / denominator : -Double.infinity
    }
}
