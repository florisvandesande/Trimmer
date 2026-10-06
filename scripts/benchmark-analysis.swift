// Build with: swiftc -O -parse-as-library Sources/TrimmerCore/*.swift scripts/benchmark-analysis.swift -o /tmp/trimmer-benchmark
// Run with: /tmp/trimmer-benchmark /absolute/path/to/audio
import Foundation
import AVFoundation

private final class FirstWave: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: Double?
    func record(_ time: Double) {
        lock.lock(); defer { lock.unlock() }
        if elapsed == nil { elapsed = time }
    }
    var value: Double? { lock.lock(); defer { lock.unlock() }; return elapsed }
}

@main struct AudioBenchmark {
    static func main() async throws {
        guard CommandLine.arguments.count == 2, let tools = FFmpegTools.locate() else {
            print("Usage: trimmer-benchmark /absolute/path/to/audio (requires FFmpeg)")
            return
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        for run in 1...3 {
            let started = Date()
            let first = FirstWave()
            let file = try await tools.metadata(url)
            let metadataTime = Date().timeIntervalSince(started)
            async let indexed = tools.indexed(file)
            async let decoded = tools.analyze(file) { wave in
                if wave.levels.first?.isEmpty == false { first.record(Date().timeIntervalSince(started)) }
            }
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            let playbackTime = Date().timeIntervalSince(started)
            _ = try await indexed
            let indexTime = Date().timeIntervalSince(started)
            let analysis = try await decoded
            let waveformTime = Date().timeIntervalSince(started)
            let regions = try RepeatDetector.detect(analysis, minimumDuration: 30)
            let complete = Date().timeIntervalSince(started)
            print(String(format: "run=%d metadata=%.3fs playback=%.3fs index=%.3fs first-wave=%.3fs full-wave=%.3fs detection=%.3fs",
                         run, metadataTime, playbackTime, indexTime, first.value ?? waveformTime, waveformTime, complete))
            for region in regions {
                print(String(format: "original=%.3fs repeat=%.3fs length=%.3fs", region.originalStart, region.repeatedStart, region.duration))
            }
        }
    }
}
