import SwiftUI
import TrimmerCore

let trimYellow = Color(red: 1, green: 0.79, blue: 0.16)

struct TimelineView: View {
    @ObservedObject var model: EditorModel
    let audio: AudioFile
    @State private var scrubbing = false
    @State private var resumeAfterScrub = false
    @State private var trimDragOrigin: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 28)
            let left = width * model.start / audio.duration
            let right = width * model.end / audio.duration
            let playhead = width * model.position / audio.duration
            ZStack(alignment: .topLeading) {
                VStack(spacing: 8) {
                    waveform(width: width)
                        .frame(height: 90)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if !scrubbing {
                                resumeAfterScrub = model.isPlaying; model.pause(); scrubbing = true
                            }
                            model.seek(value.location.x / width * audio.duration)
                        }.onEnded { _ in
                            scrubbing = false
                            if resumeAfterScrub { model.togglePlayback() }
                        })
                        .accessibilityLabel("Golfvorm en afspeelpositie")
                        .accessibilityValue(timeLabel(model.position))
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
                        handle(isStart: true, width: width).offset(x: left - 10)
                        handle(isStart: false, width: width).offset(x: right - 10)
                    }
                    .frame(height: 30)
                    .accessibilityElement(children: .contain)
                }
                Rectangle().fill(Color.white.opacity(0.88))
                    .frame(width: 1, height: 120)
                    .offset(x: playhead, y: 5)
                    .allowsHitTesting(false)
                Circle().fill(Color.white).frame(width: 5, height: 5)
                    .offset(x: playhead - 2, y: 1).allowsHitTesting(false)
                if model.waveformLoading {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text(model.canPlay ? "Golfvorm berekenen…" : model.loadingMessage)
                            .font(.system(size: 12))
                    }
                    .padding(12).background(.ultraThinMaterial, in: Capsule())
                    .position(x: width / 2, y: 45)
                }
            }
            .padding(.horizontal, 14)
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
            guard !model.peaks.isEmpty else { return }
            let columns = max(1, Int(size.width / 3))
            let maxPeak = max(0.001, model.peaks.max() ?? 1)
            for column in 0..<columns {
                let first = column * model.peaks.count / columns
                let last = min(model.peaks.count, max(first + 1, (column + 1) * model.peaks.count / columns))
                let peak = model.peaks[first..<last].max() ?? 0
                let height = max(2, Double(peak / maxPeak) * (size.height - 20))
                let time = (Double(column) + 0.5) / Double(columns) * audio.duration
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
                        model.beginTrimming()
                        if value.translation.width == 0 { return }
                    }
                    guard let origin = trimDragOrigin else { return }
                    // Preserve the grab offset: clicking either side of a handle must not jump it.
                    let time = origin + value.translation.width / width * audio.duration
                    if isStart { model.setStart(time, timelineWidth: width) }
                    else { model.setEnd(time, timelineWidth: width) }
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
}
