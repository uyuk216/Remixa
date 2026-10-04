import Foundation

/// Plain-value settings for the effects rack. Kept separate from the AVAudioUnit graph
/// so it can be serialized later (v0.2 presets) without depending on AVFoundation nodes.
struct EffectsRackSettings: Equatable, Sendable {
    struct EQ: Equatable, Sendable {
        var bypass = true
        var lowGainDB: Double = 0       // -24...24
        var midGainDB: Double = 0
        var highGainDB: Double = 0
    }

    struct Filter: Equatable, Sendable {
        var bypass = true
        var isHighPass = false          // false = low-pass
        var cutoffHz: Double = 1000     // 20...20000
    }

    struct Reverb: Equatable, Sendable {
        var bypass = true
        var wetDryMix: Double = 30      // 0...100
        var presetIndex: Int = 0        // maps to AVAudioUnitReverbPreset
    }

    struct Delay: Equatable, Sendable {
        var bypass = true
        var delayTimeSec: Double = 0.3  // 0...2
        var feedback: Double = 30       // 0...100
        var wetDryMix: Double = 30      // 0...100
    }

    struct Distortion: Equatable, Sendable {
        var bypass = true
        var presetIndex: Int = 0
        var wetDryMix: Double = 50      // 0...100
    }

    var eq = EQ()
    var filter = Filter()
    var reverb = Reverb()
    var delay = Delay()
    var distortion = Distortion()
}
