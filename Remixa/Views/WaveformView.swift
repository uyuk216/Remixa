import SwiftUI

struct WaveformView: View {
    @EnvironmentObject var document: AudioDocument
    @ObservedObject var engine: AudioEngineController

    @State private var zoom: Double = 1.0
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let duration = max(document.duration, 0.001)

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawWaveform(context: context, size: size)
                    drawSelection(context: context, size: size, duration: duration)
                    drawPlayhead(context: context, size: size, duration: duration)
                }
                .background(Color.black.opacity(0.05))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            let startSec = time(for: value.startLocation.x, width: width, duration: duration)
                            let currentSec = time(for: value.location.x, width: width, duration: duration)
                            if dragStart == nil { dragStart = startSec }
                            let lower = min(dragStart ?? startSec, currentSec)
                            let upper = max(dragStart ?? startSec, currentSec)
                            document.selection = lower...max(upper, lower + 0.001)
                        }
                        .onEnded { _ in
                            dragStart = nil
                        }
                )
                .onTapGesture { location in
                    let sec = time(for: location.x, width: width, duration: duration)
                    engine.seek(to: sec)
                }
            }
            .frame(width: width, height: height)
        }
    }

    private func time(for x: CGFloat, width: CGFloat, duration: Double) -> Double {
        max(0, min(duration, Double(x / width) * duration))
    }

    private func drawWaveform(context: GraphicsContext, size: CGSize) {
        let peaks = document.waveformPeaks
        guard !peaks.isEmpty else { return }
        let midY = size.height / 2
        let stepX = size.width / CGFloat(peaks.count)
        var path = Path()
        for (i, peak) in peaks.enumerated() {
            let x = CGFloat(i) * stepX
            let h = CGFloat(peak) * midY
            path.move(to: CGPoint(x: x, y: midY - h))
            path.addLine(to: CGPoint(x: x, y: midY + h))
        }
        context.stroke(path, with: .color(.accentColor), lineWidth: max(stepX, 1))
    }

    private func drawSelection(context: GraphicsContext, size: CGSize, duration: Double) {
        guard let selection = document.selection else { return }
        let x0 = CGFloat(selection.lowerBound / duration) * size.width
        let x1 = CGFloat(selection.upperBound / duration) * size.width
        let rect = CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: size.height)
        context.fill(Path(rect), with: .color(.yellow.opacity(0.25)))
    }

    private func drawPlayhead(context: GraphicsContext, size: CGSize, duration: Double) {
        let x = CGFloat(engine.currentTime / duration) * size.width
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(path, with: .color(.red), lineWidth: 1.5)
    }
}
