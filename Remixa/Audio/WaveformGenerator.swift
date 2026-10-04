import AVFoundation

enum WaveformGenerator {
    /// Downsamples the buffer into `targetCount` peak values (0...1) for display.
    static func peaks(from buffer: AVAudioPCMBuffer, targetCount: Int) -> [Float] {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let bucketSize = max(1, frameCount / targetCount)
        var result: [Float] = []
        result.reserveCapacity(targetCount)
        var i = 0
        while i < frameCount {
            let end = min(i + bucketSize, frameCount)
            var peak: Float = 0
            for ch in 0..<channelCount {
                for j in i..<end {
                    peak = max(peak, abs(data[ch][j]))
                }
            }
            result.append(peak)
            i = end
        }
        return result
    }

    /// Reads an audio file in small blocks and keeps only the requested peak bins.
    /// This avoids decoding and retaining a second full-length PCM buffer just to draw a waveform.
    static func peaks(from url: URL, targetCount: Int) throws -> (peaks: [Float], duration: Double) {
        let file = try AVAudioFile(forReading: url)
        let totalFrames = Int64(file.length)
        let sampleRate = file.processingFormat.sampleRate
        guard totalFrames > 0, sampleRate > 0, targetCount > 0,
              let channels = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768) else {
            return ([], sampleRate > 0 ? Double(totalFrames) / sampleRate : 0)
        }

        let bucketCount = min(targetCount, Int(min(totalFrames, Int64(Int.max))))
        var result = [Float](repeating: 0, count: bucketCount)
        let channelCount = Int(file.processingFormat.channelCount)
        let chunkCapacity: AVAudioFrameCount = 32768
        var framesRead: Int64 = 0
        var bucketIndex = 0
        var bucketEnd = totalFrames / Int64(bucketCount)

        while framesRead < totalFrames {
            let request = AVAudioFrameCount(min(Int64(chunkCapacity), totalFrames - framesRead))
            try file.read(into: channels, frameCount: request)
            let count = Int64(channels.frameLength)
            guard count > 0, let data = channels.floatChannelData else { break }
            let chunkEnd = framesRead + count
            var cursor = framesRead

            while cursor < chunkEnd, bucketIndex < bucketCount {
                let end = min(chunkEnd, max(cursor + 1, bucketEnd))
                let localStart = Int(cursor - framesRead)
                let localEnd = Int(end - framesRead)
                var peak = result[bucketIndex]
                for channel in 0..<channelCount {
                    for frame in localStart..<localEnd {
                        peak = max(peak, abs(data[channel][frame]))
                    }
                }
                result[bucketIndex] = peak
                cursor = end
                if cursor >= bucketEnd, bucketIndex + 1 < bucketCount {
                    bucketIndex += 1
                    bucketEnd = (Int64(bucketIndex + 1) * totalFrames) / Int64(bucketCount)
                } else if cursor >= bucketEnd {
                    bucketIndex += 1
                }
            }
            framesRead = chunkEnd
        }

        return (result, Double(totalFrames) / sampleRate)
    }
}

/// Shared bounded-memory AVAudioFile helpers for timeline playback and export.
enum AudioFileRegionReader {
    static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    static func read(url: URL, sourceStart: Double, duration: Double) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, sourceStart.isFinite, duration.isFinite, duration > 0 else {
            throw NSError(domain: "Remixa", code: 10, userInfo: [NSLocalizedDescriptionKey: "音声区間の指定が不正です"])
        }
        let sourceDuration = Double(file.length) / sampleRate
        let startSeconds = min(sourceDuration, max(0, sourceStart))
        let startFrame = AVAudioFramePosition(startSeconds * sampleRate)
        let availableFrames = file.length - startFrame
        let safeDuration = min(duration, Double(availableFrames) / sampleRate)
        let requestedFrames = AVAudioFramePosition((safeDuration * sampleRate).rounded(.up))
        let frameCount = min(availableFrames, max(0, requestedFrames))
        guard frameCount > 0, frameCount <= AVAudioFramePosition(UInt32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw NSError(domain: "Remixa", code: 10, userInfo: [NSLocalizedDescriptionKey: "音声区間を読み込めませんでした"])
        }
        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: AVAudioFrameCount(frameCount))
        guard buffer.frameLength > 0 else {
            throw NSError(domain: "Remixa", code: 10, userInfo: [NSLocalizedDescriptionKey: "音声区間が空です"])
        }
        return buffer
    }
}
