import SwiftUI

struct EffectsRackView: View {
    @EnvironmentObject var document: AudioDocument

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
        EffectBox(title: "3バンドEQ", bypass: $document.effects.eq.bypass) {
            sliderRow("Low", value: $document.effects.eq.lowGainDB, range: -24...24, unit: "dB")
            sliderRow("Mid", value: $document.effects.eq.midGainDB, range: -24...24, unit: "dB")
            sliderRow("High", value: $document.effects.eq.highGainDB, range: -24...24, unit: "dB")
        }
    }

    private var filterSection: some View {
        EffectBox(title: "フィルター", bypass: $document.effects.filter.bypass) {
            Picker("種類", selection: $document.effects.filter.isHighPass) {
                Text("ローパス").tag(false)
                Text("ハイパス").tag(true)
            }
            .pickerStyle(.segmented)
            sliderRow("周波数", value: $document.effects.filter.cutoffHz, range: 20...20000, unit: "Hz")
        }
    }

    private var reverbSection: some View {
        EffectBox(title: "リバーブ", bypass: $document.effects.reverb.bypass) {
            sliderRow("Wet/Dry", value: $document.effects.reverb.wetDryMix, range: 0...100, unit: "%")
        }
    }

    private var delaySection: some View {
        EffectBox(title: "ディレイ", bypass: $document.effects.delay.bypass) {
            sliderRow("時間", value: $document.effects.delay.delayTimeSec, range: 0...2, unit: "秒")
            sliderRow("フィードバック", value: $document.effects.delay.feedback, range: 0...100, unit: "%")
            sliderRow("Wet/Dry", value: $document.effects.delay.wetDryMix, range: 0...100, unit: "%")
        }
    }

    private var distortionSection: some View {
        EffectBox(title: "ディストーション", bypass: $document.effects.distortion.bypass) {
            sliderRow("Wet/Dry", value: $document.effects.distortion.wetDryMix, range: 0...100, unit: "%")
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range)
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
