import SwiftUI
import Combine
import TrimmerCore

let trimYellow = Color(red: 1, green: 0.79, blue: 0.16)

struct TimelineView: View {
    @ObservedObject var model: EditorModel
    let audio: AudioFile
    @State private var scrubbing = false
    @State private var resumeAfterScrub = false
    @State private var trimDragOrigin: Double?
    @State private var dragViewportOrigin = 0.0
    @State private var dragTranslation = 0.0
    @State private var dragPointer = 0.0
    @State private var draggingStart = true
    private let autoScroll = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 28)
            let timeline = TimelineGeometry(start: model.visibleStart, duration: model.viewDuration, width: width)
            let left = timeline.x(for: model.start)
            let right = timeline.x(for: model.end)
            let playhead = timeline.x(for: model.position)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 8) {
                    waveform(width: width)
                        .frame(width: width, height: 90)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if !scrubbing {
                                resumeAfterScrub = model.isPlaying; model.pause(); scrubbing = true
                            }
                            model.seek(model.visibleStart + value.location.x / width * model.viewDuration)
                        }.onEnded { _ in
                            scrubbing = false
                            if resumeAfterScrub { model.togglePlayback() }
                        })
                        .accessibilityLabel("Golfvorm en afspeelpositie")
                        .accessibilityValue(timeLabel(model.position) + ", zichtbaar " + timeLabel(model.visibleStart) + " tot " + timeLabel(model.visibleStart + model.viewDuration))
                        .accessibilityScrollAction { edge in
                            model.scroll((edge == .leading || edge == .top ? 1 : -1) * model.viewDuration * 0.8)
                        }
                        .accessibilityAdjustableAction { direction in
                            model.seek(model.position + (direction == .increment ? 1 : -1))
                        }
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.045))
                        Canvas { context, size in
                            for x in stride(from: 8.0, to: size.width, by: 8.0) {
                                let mark = Path(CGRect(x: x, y: 9, width: 1, height: 12))
                                context.fill(mark, with: .color(.white.opacity(0.1)))
                            }
                        }
                        RoundedRectangle(cornerRadius: 6)
                            .fill(trimYellow.opacity(0.12))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(trimYellow, lineWidth: 2))
                            .frame(width: max(2, right - left))
                            .offset(x: left)
                        if timeline.contains(left) || (trimDragOrigin != nil && draggingStart) { handle(isStart: true, width: width).offset(x: left - 10) }
                        if timeline.contains(right) || (trimDragOrigin != nil && !draggingStart) { handle(isStart: false, width: width).offset(x: right - 10) }
                    }
                    .frame(width: width, height: 30, alignment: .leading)
                    .disabled(!model.canTrim)
                    .accessibilityElement(children: .contain)
                }
                Rectangle().fill(Color.white.opacity(0.88))
                    .frame(width: 1, height: 120)
                    .offset(x: playhead, y: 5)
                    .allowsHitTesting(false)
                Circle().fill(Color.white).frame(width: 5, height: 5)
                    .offset(x: playhead - 2, y: 1).allowsHitTesting(false)
                if model.waveformLoading && model.waveform.levels.first?.isEmpty != false {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text(model.canPlay ? "Golfvorm berekenen…" : model.loadingMessage)
                            .font(.system(size: 12))
                    }
                    .padding(12).background(.ultraThinMaterial, in: Capsule())
                    .position(x: width / 2, y: 45)
                }
            }
            .frame(width: width, height: 128, alignment: .topLeading)
            .background(TimelineGestures(zoom: { factor, anchor in model.zoom(factor, anchor: anchor) },
                                         scroll: { pixels in model.scroll(pixels / width * model.viewDuration) })
                .frame(width: width, height: 128))
            .onReceive(autoScroll) { _ in
                guard trimDragOrigin != nil else { return }
                let direction = dragPointer < 24 ? -1.0 : dragPointer > width - 24 ? 1.0 : 0
                if direction != 0 {
                    model.scroll(direction * model.viewDuration / 90)
                    updateDrag(width: width)
                }
            }
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
            .clipped()
        }
        .frame(height: 128)
    }

    private func waveform(width: Double) -> some View {
        Canvas { context, size in
            let midpoint = size.height / 2
            context.stroke(Path { p in p.move(to: CGPoint(x: 0, y: midpoint)); p.addLine(to: CGPoint(x: size.width, y: midpoint)) },
                           with: .color(.white.opacity(0.08)), lineWidth: 1)
            for step in 0...8 {
                let x = size.width * Double(step) / 8
                context.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(.white.opacity(0.035)), lineWidth: 1)
            }
            let edges = Array(Set(model.repeats.flatMap(\.edges))).sorted()
            for (from, to) in zip(edges, edges.dropFirst()) {
                let midpoint = (from + to) / 2
                let repeated = model.repeats.contains { midpoint >= $0.repeatedStart && midpoint < $0.repeatedStart + $0.duration }
                let original = model.repeats.contains { midpoint >= $0.originalStart && midpoint < $0.originalStart + $0.duration }
                guard repeated || original else { continue }
                let left = max(0, (from - model.visibleStart) / model.viewDuration * size.width)
                let right = min(size.width, (to - model.visibleStart) / model.viewDuration * size.width)
                if right > left {
                    context.fill(Path(CGRect(x: left, y: 0, width: right - left, height: size.height)),
                                 with: .color(trimYellow.opacity(repeated ? 0.30 : 0.15)))
                }
            }
            guard model.waveform.levels.first?.isEmpty == false else { return }
            let columns = max(1, Int(size.width / 3))
            let maxPeak = model.waveform.maximum
            for column in 0..<columns {
                let from = model.visibleStart + Double(column) / Double(columns) * model.viewDuration
                let to = model.visibleStart + Double(column + 1) / Double(columns) * model.viewDuration
                let peak = model.waveform.peak(from: from, to: to)
                let height = max(2, Double(peak / maxPeak) * (size.height - 20))
                let time = (from + to) / 2
                let selected = time >= model.start && time <= model.end
                let rect = CGRect(x: Double(column) * size.width / Double(columns), y: midpoint - height / 2, width: 2, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1),
                             with: .color(selected ? Color(red: 0.86, green: 0.83, blue: 0.72) : .white.opacity(0.13)))
            }
        }
    }

    private func handle(isStart: Bool, width: Double) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(trimYellow)
            .overlay(HStack(spacing: 2) {
                Capsule().fill(.black.opacity(0.65)).frame(width: 1.5, height: 13)
                Capsule().fill(.black.opacity(0.65)).frame(width: 1.5, height: 13)
            })
            .frame(width: 20, height: 30)
            .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
            .contentShape(Rectangle().inset(by: -5))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trimTimeline"))
                .onChanged { value in
                    if trimDragOrigin == nil {
                        trimDragOrigin = isStart ? model.start : model.end
                        dragViewportOrigin = model.visibleStart
                        draggingStart = isStart
                        model.beginTrimming()
                        if value.translation.width == 0 { return }
                    }
                    dragTranslation = value.translation.width
                    dragPointer = value.location.x - 14
                    updateDrag(width: width)
                }
                .onEnded { _ in
                    trimDragOrigin = nil
                    model.endTrimming()
                })
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .accessibilityLabel(isStart ? "Begin van selectie" : "Einde van selectie")
            .accessibilityValue(timeLabel(isStart ? model.start : model.end))
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 0.1 : -0.1
                if isStart { model.setStart(model.start + delta) } else { model.setEnd(model.end + delta) }
            }
    }
    private func updateDrag(width: Double) {
        guard let origin = trimDragOrigin else { return }
        let time = origin + dragTranslation / width * model.viewDuration + model.visibleStart - dragViewportOrigin
        if draggingStart { model.setStart(time, timelineWidth: width) }
        else { model.setEnd(time, timelineWidth: width) }
    }

}
