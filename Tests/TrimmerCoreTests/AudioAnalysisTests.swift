import XCTest
@testable import TrimmerCore

final class AudioAnalysisTests: XCTestCase {
    func testPeakPyramidMatchesDirectRangeMaximum() {
        let peaks = (0..<10001).map { Float(($0 * 719) % 1000) / 1000 }
        let waveform = Waveform(peaks: peaks)
        for first in stride(from: 0, to: 9900, by: 97) {
            let last = first + 101
            XCTAssertEqual(waveform.peak(from: Double(first) / 1000, to: Double(last) / 1000),
                           peaks[first..<last].max()!, accuracy: 0.001)
        }
        XCTAssertEqual(waveform.peak(from: 100, to: 101), 0)
        XCTAssertEqual(Waveform(peaks: []).peak(from: 0, to: 1), 0)
    }

    private func recording(_ samples: [Float]) async throws -> AudioAnalysis {
        guard let tools = FFmpegTools.locate() else { throw XCTSkip("FFmpeg is required") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = folder.appendingPathComponent("audio.f32")
        try samples.withUnsafeBytes { try Data($0).write(to: raw) }
        let wav = folder.appendingPathComponent("audio.wav")
        try await Command.run(tools.ffmpeg, ["-v", "error", "-f", "f32le", "-ar", "8000", "-ac", "1", "-i", raw.path, wav.path])
        return try await tools.analyze(try await tools.metadata(wav))
    }

    private func passage(seconds: Int, seed: UInt64 = 7) -> [Float] {
        var state = seed
        var result: [Float] = []
        var phase = 0.0
        for i in 0..<(seconds * 8000) {
            state = state &* 6364136223846793005 &+ 1
            let noise = Double((state >> 32) & 65535) / 32768 - 1
            let t = Double(i) / 8000
            phase += 2 * .pi * (180 + 700 * (0.5 + 0.5 * sin(t * 1.713))) / 8000
            let gain = 0.1 + 0.3 * (0.5 + 0.5 * sin(t * 2.312 + cos(t * 0.83)))
            result.append(Float(gain * (0.6 * sin(phase) + noise * 0.4)))
        }
        return result
    }

    func testExactAndVolumeChangedCopiesAndMinimumDuration() async throws {
        let source = passage(seconds: 8)
        let silence = [Float](repeating: 0, count: 8000)
        let analysis = try await recording(source + silence + source.map { $0 * 0.65 } + silence + source)
        let matches = try RepeatDetector.detect(analysis, minimumDuration: 5)
        XCTAssertTrue(matches.contains { abs($0.repeatedStart - 9) < 0.5 && $0.originalStart < 0.5 && $0.duration > 7 })
        XCTAssertTrue(matches.contains { abs($0.repeatedStart - 18) < 0.5 && $0.originalStart < 0.5 })
        XCTAssertTrue(try RepeatDetector.detect(analysis, minimumDuration: 10).isEmpty)
    }

    func testSilenceAndNonRepeatedNoiseHaveNoMatches() async throws {
        let silent = try await recording([Float](repeating: 0, count: 8000 * 12))
        XCTAssertTrue(try RepeatDetector.detect(silent, minimumDuration: 1).isEmpty)
        var state: UInt64 = 19
        let noise: [Float] = (0..<(8000 * 15)).map { _ in
            state = state &* 6364136223846793005 &+ 1
            return Float((state >> 32) & 65535) / 32768 - 1
        }
        let random = try await recording(noise)
        XCTAssertTrue(try RepeatDetector.detect(random, minimumDuration: 2).isEmpty)
    }

    func testFadedTransitionPreservesConfirmedInterior() async throws {
        let source = passage(seconds: 10)
        let faded = source.enumerated().map { i, sample in sample * Float(min(1, Double(i) / 8000)) }
        let analysis = try await recording(source + faded)
        let matches = try RepeatDetector.detect(analysis, minimumDuration: 5)
        XCTAssertTrue(matches.contains { $0.repeatedStart >= 10 && $0.repeatedStart < 12 && $0.duration >= 7 })
    }

    func testAnalysisAndDetectionRespectCancellation() async throws {
        let analysis = try await recording(passage(seconds: 4) + passage(seconds: 4))
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try RepeatDetector.detect(analysis, minimumDuration: 1)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertTrue(try RepeatDetector.detect(analysis, minimumDuration: 1e100).isEmpty)
    }

    func testAngelsWhenExplicitlyProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["TRIMMER_TEST_AUDIO"], let tools = FFmpegTools.locate() else {
            throw XCTSkip("Set TRIMMER_TEST_AUDIO for the local acceptance recording")
        }
        let analysis = try await tools.analyze(try await tools.metadata(URL(fileURLWithPath: path)))
        let matches = try RepeatDetector.detect(analysis, minimumDuration: 30)
        XCTAssertTrue(matches.contains { (520...535).contains($0.repeatedStart) && $0.duration > 60 })
    }
}
