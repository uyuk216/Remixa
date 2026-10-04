import SwiftUI

@MainActor
struct AutomationLaneView: View {
    @EnvironmentObject private var project: RemixaProject
    @ObservedObject var track: Track
    let parameter: AutomationParameter
    let pixelsPerSecond: Double
    let width: CGFloat
    let height: CGFloat

    @FocusState private var isFocused: Bool
    @State private var selectedPointID: UUID?
    @State private var draggingPointID: UUID?
    @State private var dragStartTime = 0.0
    @State private var dragStartValue = 0.0

    private var lane: AutomationLane {
        track.automation.first(where: { $0.parameter == parameter })
            ?? AutomationLane(parameter: parameter, points: [])
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.accentColor.opacity(0.035))
                Canvas { context, size in
                    if lane.points.isEmpty {
                        context.stroke(
                            curvePath(in: size),
                            with: .color(.secondary.opacity(0.65)),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                        )
                    } else {
                        context.stroke(
                            curvePath(in: size),
                            with: .color(Color.accentColor),
                            lineWidth: 2
                        )
                    }
                }
                ForEach(lane.points) { point in
                    pointHandle(point, in: geometry.size)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(parameter.japaneseName)
                        .font(.system(size: 9, weight: .semibold))
                    if let selectedPoint = lane.points.first(where: { $0.id == selectedPointID }) {
                        Text(parameter.displayValue(selectedPoint.value))
                            .font(.system(size: 8, design: .monospaced))
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                .padding(4)
                .allowsHitTesting(false)
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .coordinateSpace(name: "automationLane")
            .gesture(
                SpatialTapGesture(count: 1)
                    .onEnded { value in addPoint(at: value.location, in: geometry.size) }
            )
            .onDeleteCommand(perform: deleteSelectedPoint)
            .focused($isFocused)
            .focusable()
            .accessibilityLabel("\(parameter.japaneseName)オートメーション")
            .accessibilityHint("クリックでポイントを追加、ポイントをドラッグして移動、ダブルクリックまたは削除キーで削除")
        }
        .frame(width: width, height: height)
        .onChange(of: parameter) { _, _ in selectedPointID = nil }
    }

    private var baseValue: Double {
        switch parameter {
        case .volume: track.volume
        case .pan: track.pan
        case .filterCutoff: track.effects.filter.cutoffHz
        case .reverbWet: track.effects.reverb.wetDryMix
        case .delayWet: track.effects.delay.wetDryMix
        case .distortionWet: track.effects.distortion.wetDryMix
        }
    }

    private func curvePath(in size: CGSize) -> Path {
        var path = Path()
        guard pixelsPerSecond > 0 else { return path }
        let sampleCount = max(2, Int(size.width / 8))
        for sample in 0...sampleCount {
            let x = size.width * CGFloat(sample) / CGFloat(sampleCount)
            let time = Double(x) / pixelsPerSecond
            let value = lane.value(at: time) ?? baseValue
            let point = CGPoint(x: x, y: yPosition(for: value, height: size.height))
            if sample == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    private func pointHandle(_ point: AutomationPoint, in size: CGSize) -> some View {
        Circle()
            .fill(selectedPointID == point.id ? Color.white : Color.accentColor)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
            .frame(width: 11, height: 11)
            .position(
                x: CGFloat(point.time * pixelsPerSecond),
                y: yPosition(for: point.value, height: size.height)
            )
            .contentShape(Circle())
            .onTapGesture { selectedPointID = point.id; isFocused = true }
            .onTapGesture(count: 2) { deletePoint(id: point.id) }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named("automationLane"))
                    .onChanged { value in
                        if draggingPointID != point.id {
                            project.beginUndoCoalescing()
                            draggingPointID = point.id
                            dragStartTime = point.time
                            dragStartValue = point.value
                            selectedPointID = point.id
                            isFocused = true
                        }
                        let usableHeight = max(1, size.height - 16)
                        let startNormalized = parameter.normalized(dragStartValue)
                        let normalized = startNormalized - Double(value.translation.height) / Double(usableHeight)
                        let updatedPoints = lane.points.map { current in
                            guard current.id == point.id else { return current }
                            return AutomationPoint(
                                id: current.id,
                                time: max(0, dragStartTime + Double(value.translation.width) / pixelsPerSecond),
                                value: parameter.value(normalized: normalized)
                            )
                        }
                        project.setAutomation(updatedPoints, for: parameter, on: track)
                    }
                    .onEnded { _ in
                        project.endUndoCoalescing()
                        draggingPointID = nil
                    }
            )
            .help("\(parameter.displayValue(point.value)) · \(point.time, specifier: "%.2f")秒")
            .accessibilityLabel("\(parameter.displayValue(point.value))、\(point.time, specifier: "%.2f")秒")
    }

    private func yPosition(for value: Double, height: CGFloat) -> CGFloat {
        let normalized = parameter.normalized(value)
        let usableHeight = max(1, height - 16)
        return height - 8 - CGFloat(normalized) * usableHeight
    }

    private func addPoint(at location: CGPoint, in size: CGSize) {
        isFocused = true
        let time = max(0, Double(location.x) / pixelsPerSecond)
        if let nearby = lane.points.min(by: {
            abs($0.time * pixelsPerSecond - Double(location.x)) < abs($1.time * pixelsPerSecond - Double(location.x))
        }), abs(nearby.time * pixelsPerSecond - Double(location.x)) < 14 {
            selectedPointID = nearby.id
            return
        }
        let normalized = 1 - (Double(location.y) - 8) / Double(max(1, size.height - 16))
        let point = AutomationPoint(time: time, value: parameter.value(normalized: normalized))
        project.setAutomation(lane.points + [point], for: parameter, on: track)
        selectedPointID = point.id
    }

    private func deleteSelectedPoint() {
        guard let selectedPointID else { return }
        deletePoint(id: selectedPointID)
    }

    private func deletePoint(id: UUID) {
        let remaining = lane.points.filter { $0.id != id }
        guard remaining.count != lane.points.count else { return }
        project.setAutomation(remaining, for: parameter, on: track)
        if selectedPointID == id { selectedPointID = nil }
    }
}
