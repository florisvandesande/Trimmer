import Foundation
import Accelerate

/// Immutable, time-aligned peak levels. Level zero has one peak per millisecond.
public struct Waveform: Sendable {
    public let levels: [[Float]]
    public let maximum: Float
    public init(peaks: [Float]) {
        var levels = [peaks]
        var current = peaks
        while current.count > 1 {
            current = stride(from: 0, to: current.count, by: 2).map {
                max(current[$0], $0 + 1 < current.count ? current[$0 + 1] : 0)
            }
            levels.append(current)
        }
        self.levels = levels
        maximum = max(0.001, current.first ?? 0)
    }
    public func peak(from start: Double, to end: Double) -> Float {
        guard let base = levels.first, !base.isEmpty else { return 0 }
        var left = max(0, Int(floor(start * 1000)))
        var right = min(base.count, Int(ceil(end * 1000)))
        guard left < right else { return 0 }
        var level = 0
        var result: Float = 0
        while left < right {
            if left & 1 == 1 { result = max(result, levels[level][left]); left += 1 }
            if right & 1 == 1 { right -= 1; result = max(result, levels[level][right]) }
            left /= 2; right /= 2; level += 1
        }
        return result
    }
}

public struct RepeatRegion: Sendable, Equatable {
    public let originalStart: Double
    public let repeatedStart: Double
    public let duration: Double
    public init(originalStart: Double, repeatedStart: Double, duration: Double) {
        self.originalStart = originalStart; self.repeatedStart = repeatedStart; self.duration = duration
    }
    public var edges: [Double] {
        [originalStart, originalStart + duration, repeatedStart, repeatedStart + duration]
    }
}

public struct AudioAnalysis: Sendable {
    public let waveform: Waveform
    // Ten spectral fingerprints/second, plus a small 200 Hz amplitude envelope for boundary verification.
    let fingerprints: [[Float]]
    let energy: [Float]
    let signal: [Float]
}

/// Only accessed by Command's single output-reader thread, then after that reader completes.
private final class AnalysisAccumulator: @unchecked Sendable {
    var pending = Data()
    var peaks: [Float] = []
    var block: [Float] = []
    var fingerprints: [[Float]] = []
    var energy: [Float] = []
    var signal: [Float] = []
    var peak: Float = 0
    var frames = 0
    var low: Float = 0
    var lastPublish = Date.distantPast
    let channels: Int
    let publish: @Sendable (Waveform) -> Void
    let setup = vDSP_DFT_zop_CreateSetup(nil, 1024, .FORWARD)!
    init(channels: Int, publish: @escaping @Sendable (Waveform) -> Void) {
        self.channels = channels; self.publish = publish
    }
    deinit { vDSP_DFT_DestroySetup(setup) }
    func append(_ data: Data) {
        pending.append(data)
        let strideBytes = channels * 4
        let count = pending.count / strideBytes
        pending.withUnsafeBytes { bytes in
            for frame in 0..<count {
                var mono: Float = 0
                for channel in 0..<channels {
                    let bits = bytes.loadUnaligned(fromByteOffset: frame * strideBytes + channel * 4, as: UInt32.self)
                    let value = Float(bitPattern: UInt32(littleEndian: bits))
                    if value.isFinite {
                        peak = max(peak, abs(value))
                        // A reference channel avoids cancellation in out-of-phase stereo.
                        if channel == 0 { mono = value }
                    }
                }
                frames += 1; block.append(mono); low += mono * mono
                if frames % 8 == 0 { peaks.append(peak); peak = 0 }
                if frames % 40 == 0 { signal.append(sqrt(low / 40)); low = 0 }
                if block.count == 800 { fingerprint(); block.removeAll(keepingCapacity: true) }
            }
        }
        pending.removeFirst(count * strideBytes)
        if Date().timeIntervalSince(lastPublish) >= 0.2 {
            lastPublish = Date(); publish(Waveform(peaks: peaks))
        }
    }
    func fingerprint() {
        var real = [Float](repeating: 0, count: 1024)
        let imaginary = real
        var outReal = real, outImaginary = real
        var sum: Float = 0
        for i in block.indices {
            sum += block[i] * block[i]
            real[i] = block[i] * Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / 799))
        }
        vDSP_DFT_Execute(setup, real, imaginary, &outReal, &outImaginary)
        let limits = [3, 5, 8, 12, 18, 26, 38, 54, 76, 106, 146, 198, 266, 350, 440, 512]
        var features: [Float] = []
        for band in 0..<15 {
            var power: Float = 0
            for i in limits[band]..<limits[band + 1] {
                power += outReal[i] * outReal[i] + outImaginary[i] * outImaginary[i]
            }
            features.append(log(max(1e-12, power)))
        }
        let mean = features.reduce(0, +) / Float(features.count)
        features = features.map { $0 - mean }
        let norm = sqrt(features.reduce(0) { $0 + $1 * $1 })
        fingerprints.append(features.map { $0 / max(0.001, norm) })
        energy.append(sqrt(sum / 800))
    }
    func finish() -> AudioAnalysis {
        if frames % 8 != 0 { peaks.append(peak) }
        let waveform = Waveform(peaks: peaks)
        publish(waveform)
        return AudioAnalysis(waveform: waveform, fingerprints: fingerprints, energy: energy, signal: signal)
    }
}

extension FFmpegTools {
    public func analyze(_ audio: AudioFile,
                        progress: @escaping @Sendable (Waveform) -> Void = { _ in }) async throws -> AudioAnalysis {
        let accumulator = AnalysisAccumulator(channels: audio.channels, publish: progress)
        try await Command.run(ffmpeg, ["-v", "error", "-nostdin", "-i", audio.url.path,
            "-map", "0:a:0", "-vn", "-ar", "8000", "-c:a", "pcm_f32le", "-f", "f32le", "-"],
            onOutput: { accumulator.append($0) })
        try Task.checkCancellation()
        return accumulator.finish()
    }
}

public enum RepeatDetector {
    /// Fingerprint indexing avoids an all-pairs comparison of the entire recording.
    public static func detect(_ analysis: AudioAnalysis, minimumDuration: Double,
                              progress: @Sendable ([RepeatRegion]) -> Void = { _ in }) throws -> [RepeatRegion] {
        guard minimumDuration.isFinite, minimumDuration >= 1 else { return [] }
        let features = analysis.fingerprints, energy = analysis.energy
        guard minimumDuration <= Double(features.count) / 20 else { return [] }
        let minimum = max(10, Int(ceil(minimumDuration * 10)))
        guard features.count >= minimum * 2 else { return [] }
        var index: [Int: [Int]] = [:]
        var votes: [Int: Int] = [:]
        func hash(_ f: [Float]) -> Int {
            var value = 0
            for i in 0..<14 where f[i] > f[i + 1] { value |= 1 << i }
            return value
        }
        func similarity(_ a: Int, _ b: Int) -> Float {
            zip(features[a], features[b]).reduce(0) { $0 + $1.0 * $1.1 }
        }
        for i in features.indices {
            if i % 100 == 0 { try Task.checkCancellation() }
            guard energy[i] > 0.0001 else { continue }
            let key = hash(features[i])
            // Neighboring hashes tolerate small codec and transition differences.
            for candidateKey in [key] + (0..<14).map({ key ^ (1 << $0) }) {
                for j in index[candidateKey, default: []] where i - j >= minimum {
                    if similarity(i, j) > 0.985 { votes[i - j, default: 0] += 1 }
                }
            }
            var bucket = index[key, default: []]
            // Retain early anchors as well as recent examples, with bounded candidate work.
            if bucket.count < 64 { bucket.append(i) }
            else { bucket.remove(at: 32); bucket.append(i) }
            index[key] = bucket
        }
        let offsets = votes.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .filter { $0.value >= max(5, minimum / 8) }.prefix(32).map(\.key)
        var results: [RepeatRegion] = []
        var usedOffsets: [Int] = []
        for offset in offsets {
            try Task.checkCancellation()
            if usedOffsets.contains(where: { abs($0 - offset) <= 2 }) { continue }
            usedOffsets.append(offset)
            var runStart: Int?
            var lastGood = 0
            func finish() {
                guard let first = runStart else { return }
                defer { runStart = nil }
                let length = lastGood + 1 - first
                guard length >= minimum else { return }
                // Temporal energy correlation rejects steady tones and similar ambience.
                let a = Array(energy[(first - offset)...(lastGood - offset)])
                let b = Array(energy[first...lastGood])
                let margin = min(10, length / 5)
                guard correlation(Array(a[margin..<(length - margin)]), Array(b[margin..<(length - margin)])) > 0.90 else { return }
                var refined = refine(analysis.signal, original: Double(first - offset) / 10,
                                     repeated: Double(first) / 10, duration: Double(length) / 10)
                guard refined.duration >= minimumDuration else { return }
                for earlier in results.reversed() where refined.originalStart >= earlier.repeatedStart - 0.1
                    && refined.originalStart + refined.duration <= earlier.repeatedStart + earlier.duration + 0.1 {
                    refined = RepeatRegion(originalStart: max(0, earlier.originalStart + refined.originalStart - earlier.repeatedStart),
                                           repeatedStart: refined.repeatedStart, duration: refined.duration)
                }
                if results.contains(where: {
                    min($0.repeatedStart + $0.duration, refined.repeatedStart + refined.duration)
                        - max($0.repeatedStart, refined.repeatedStart) > refined.duration * 0.8
                }) { return }
                results.append(refined)
                results.sort { $0.repeatedStart < $1.repeatedStart }
                progress(results)
            }
            for i in offset..<features.count {
                if i % 100 == 0 { try Task.checkCancellation() }
                let good = energy[i] > 0.0001 && energy[i - offset] > 0.0001 && similarity(i, i - offset) > 0.94
                if good {
                    if runStart == nil { runStart = i }
                    lastGood = i
                } else if runStart != nil && i - lastGood > 5 { finish() }
            }
            finish()
        }
        return results
    }

    private static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, a.count > 1 else { return 0 }
        let ma = a.reduce(0, +) / Float(a.count), mb = b.reduce(0, +) / Float(b.count)
        var ab: Float = 0, aa: Float = 0, bb: Float = 0
        for i in a.indices { let x = a[i] - ma, y = b[i] - mb; ab += x*y; aa += x*x; bb += y*y }
        guard aa > 1e-12, bb > 1e-12 else { return 0 }
        return ab / sqrt(aa * bb)
    }

    private static func refine(_ samples: [Float], original: Double, repeated: Double, duration: Double) -> RepeatRegion {
        let a = Int(original * 200), b = Int(repeated * 200)
        let count = min(1000, Int(duration * 200), samples.count - b)
        guard count > 100 else { return RepeatRegion(originalStart: original, repeatedStart: repeated, duration: duration) }
        var best: Float = 0; var shift = 0
        for delta in -20...20 where a + delta >= 0 && a + delta + count <= samples.count {
            let value = correlation(Array(samples[(a + delta)..<(a + delta + count)]), Array(samples[b..<(b + count)]))
            if value > best { best = value; shift = delta }
        }
        // Keep fingerprint boundaries if the amplitude envelope cannot verify alignment.
        guard best > 0.75 else { return RepeatRegion(originalStart: original, repeatedStart: repeated, duration: duration) }
        let lag = b - a - shift
        var start = b, end = min(samples.count, b + Int(duration * 200))
        func matches(_ t: Int) -> Bool {
            guard t - lag >= 0, t + 100 <= samples.count,
                  samples[t] > 0.0001, samples[t - lag] > 0.0001 else { return false }
            return correlation(Array(samples[(t - lag)..<(t - lag + 100)]), Array(samples[t..<(t + 100)])) > 0.75
        }
        while start >= 20 && matches(start - 20) { start -= 20 }
        while end + 100 <= samples.count && matches(end) { end += 20 }
        return RepeatRegion(originalStart: Double(start - lag) / 200,
                            repeatedStart: Double(start) / 200, duration: Double(end - start) / 200)
    }
}
