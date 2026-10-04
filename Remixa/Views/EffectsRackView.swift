import SwiftUI

/// Editor for one `EffectsRackSettings` value. Used both by the v0.1 single-clip
/// editor (bound to `AudioDocument.effects`) and by each v0.2 track's effects
/// popover (bound to `Track.effects`), so the two feature sets share one UI/engine.
struct EffectsRackView: View {
    @Binding var effects: EffectsRackSettings
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                eqSection
                filterSection
                reverbSection
                delaySection
                distortionSection
            }
            .padding(.vertical, 4)
        }
    }

    private var eqSection: some View {
        EffectBox(title: "3バンドEQ", bypass: $effects.eq.bypass) {
            sliderRow("Low", value: $effects.eq.lowGainDB, range: -24...24, unit: "dB")
            sliderRow("Mid", value: $effects.eq.midGainDB, range: -24...24, unit: "dB")
            sliderRow("High", value: $effects.eq.highGainDB, range: -24...24, unit: "dB")
        }
    }

    private var filterSection: some View {
        EffectBox(title: "フィルター", bypass: $effects.filter.bypass) {
            Picker("種類", selection: $effects.filter.isHighPass) {
                Text("ローパス").tag(false)
                Text("ハイパス").tag(true)
            }
            .pickerStyle(.segmented)
            sliderRow("周波数", value: $effects.filter.cutoffHz, range: 20...20000, unit: "Hz")
        }
    }

    private var reverbSection: some View {
        EffectBox(title: "リバーブ", bypass: $effects.reverb.bypass) {
            sliderRow("Wet/Dry", value: $effects.reverb.wetDryMix, range: 0...100, unit: "%")
        }
    }

    private var delaySection: some View {
        EffectBox(title: "ディレイ", bypass: $effects.delay.bypass) {
            sliderRow("時間", value: $effects.delay.delayTimeSec, range: 0...2, unit: "秒")
            sliderRow("フィードバック", value: $effects.delay.feedback, range: 0...100, unit: "%")
            sliderRow("Wet/Dry", value: $effects.delay.wetDryMix, range: 0...100, unit: "%")
        }
    }

    private var distortionSection: some View {
        EffectBox(title: "ディストーション", bypass: $effects.distortion.bypass) {
            sliderRow("Wet/Dry", value: $effects.distortion.wetDryMix, range: 0...100, unit: "%")
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range, onEditingChanged: onEditingChanged)
            Text("\(Int(value.wrappedValue))\(unit)")
                .frame(width: 60, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}

private struct EffectBox<Content: View>: View {
    let title: String
    @Binding var bypass: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Toggle("有効", isOn: Binding(get: { !bypass }, set: { bypass = !$0 }))
                    .toggleStyle(.switch)
            }
            content
                .disabled(bypass)
                .opacity(bypass ? 0.5 : 1.0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
    }
}
