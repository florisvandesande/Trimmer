import Foundation

/// All timeline elements share this mapping, including a numerically stable edge.
struct TimelineGeometry {
    let start: Double
    let duration: Double
    let width: Double

    func x(for time: Double) -> Double {
        let position = width * (time - start) / duration
        // Subtraction/division can place the exact file endpoint a few ULPs past
        // the viewport. Snap only numerical noise, not genuinely offscreen times.
        let tolerance = 0.000001
        if abs(position) <= tolerance { return 0 }
        if abs(position - width) <= tolerance { return width }
        return position
    }

    func contains(_ position: Double) -> Bool { position >= 0 && position <= width }
}
