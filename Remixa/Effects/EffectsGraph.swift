import AVFoundation

/// Builds and configures the chain of AVAudioUnit effect nodes shared between
/// live playback and offline export, so the two paths never drift apart.
final class EffectsGraph {
    let timePitch = AVAudioUnitTimePitch()
    let eq = AVAudioUnitEQ(numberOfBands: 3)
    let filter = AVAudioUnitEQ(numberOfBands: 1)
    let distortion = AVAudioUnitDistortion()
    let delay = AVAudioUnitDelay()
    let reverb = AVAudioUnitReverb()

    init() {
        // 3-band EQ: low shelf, parametric mid, high shelf.
        eq.bands[0].filterType = .lowShelf
        eq.bands[0].frequency = 150
        eq.bands[1].filterType = .parametric
        eq.bands[1].frequency = 1000
        eq.bands[1].bandwidth = 1.0
        eq.bands[2].filterType = .highShelf
        eq.bands[2].frequency = 6000
        eq.bands.forEach { $0.bypass = false }

        filter.bands[0].filterType = .lowPass
        filter.bands[0].frequency = 1000
        filter.bands[0].bypass = false
    }

    /// All nodes in signal-chain order, for attaching/connecting.
    var orderedNodes: [AVAudioNode] {
        [timePitch, eq, filter, distortion, delay, reverb]
    }

    func attach(to engine: AVAudioEngine) {
        orderedNodes.forEach { engine.attach($0) }
    }

    @discardableResult
    func connectChain(in engine: AVAudioEngine, from source: AVAudioNode, to destination: AVAudioNode, format: AVAudioFormat?) -> AVAudioNode {
        var previous = source
        for node in orderedNodes {
            engine.connect(previous, to: node, format: format)
            previous = node
        }
        engine.connect(previous, to: destination, format: format)
        return previous
    }

    func apply(_ settings: EffectsRackSettings, tempoPercent: Double, pitchSemitones: Double) {
        timePitch.rate = Float(tempoPercent / 100.0)
        timePitch.pitch = Float(pitchSemitones * 100.0) // cents

        eq.bypass = settings.eq.bypass
        eq.bands[0].gain = Float(settings.eq.lowGainDB)
        eq.bands[1].gain = Float(settings.eq.midGainDB)
        eq.bands[2].gain = Float(settings.eq.highGainDB)

        filter.bypass = settings.filter.bypass
        filter.bands[0].filterType = settings.filter.isHighPass ? .highPass : .lowPass
        filter.bands[0].frequency = Float(settings.filter.cutoffHz)

        reverb.bypass = settings.reverb.bypass
        let reverbPresets = AVAudioUnitReverbPreset.allCases
        let presetIndex = min(max(settings.reverb.presetIndex, 0), reverbPresets.count - 1)
        reverb.loadFactoryPreset(reverbPresets[presetIndex])
        reverb.wetDryMix = Float(settings.reverb.wetDryMix)

        delay.bypass = settings.delay.bypass
        delay.delayTime = settings.delay.delayTimeSec
        delay.feedback = Float(settings.delay.feedback)
        delay.wetDryMix = Float(settings.delay.wetDryMix)

        distortion.bypass = settings.distortion.bypass
        let distortionPresets = AVAudioUnitDistortionPreset.allCases
        let dIndex = min(max(settings.distortion.presetIndex, 0), distortionPresets.count - 1)
        distortion.loadFactoryPreset(distortionPresets[dIndex])
        distortion.wetDryMix = Float(settings.distortion.wetDryMix)
    }
}

extension AVAudioUnitReverbPreset: CaseIterable {
    public static var allCases: [AVAudioUnitReverbPreset] {
        [.smallRoom, .mediumRoom, .largeRoom, .mediumHall, .largeHall, .plate, .mediumChamber, .largeChamber, .cathedral, .largeRoom2, .mediumHall2, .mediumHall3, .largeHall2]
    }
}

extension AVAudioUnitDistortionPreset: CaseIterable {
    public static var allCases: [AVAudioUnitDistortionPreset] {
        [.drumsBitBrush, .drumsBufferBeats, .drumsLoFi, .multiBrokenSpeaker, .multiCellphoneConcert, .multiDecimated1, .multiDecimated2, .multiDecimated3, .multiDecimated4, .multiDistortedFunk, .multiDistortedCubed, .multiDistortedSquared, .multiEcho1, .multiEcho2, .multiEchoTight1, .multiEchoTight2, .multiEverythingIsBroken, .speechAlienChatter, .speechCosmicInterference, .speechGoldenPi, .speechRadioTower, .speechWaves]
    }
}
