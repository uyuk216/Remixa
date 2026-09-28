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
}
