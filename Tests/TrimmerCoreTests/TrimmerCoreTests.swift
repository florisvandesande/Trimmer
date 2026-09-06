import XCTest
@testable import TrimmerCore

final class TrimmerCoreTests: XCTestCase {
    func testSnappingAndSafeDefaultName() {
        let file = AudioFile(url: URL(fileURLWithPath: "/tmp/voice.recording.MP3"), duration: 1,
                             codec: "mp3", sampleRate: 44100, channels: 2, boundaries: [0, 0.25, 0.5, 0.75, 1])
        XCTAssertEqual(file.snapped(-2), 0)
        XCTAssertEqual(file.snapped(3), 1)
        XCTAssertEqual(file.snapped(0.26), 0.25)
        XCTAssertEqual(file.snapped(0.49), 0.5)
        XCTAssertEqual(file.suggestedURL.lastPathComponent, "voice.recording-trimmed.MP3")
    }

    func testStreamCopyAcrossFormats() async throws {
        guard let tools = FFmpegTools.locate() else { throw XCTSkip("FFmpeg is not installed") }
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (ext, codec) in [("mp3", "libmp3lame"), ("m4a", "aac"), ("wav", "pcm_s16le"), ("flac", "flac"), ("aiff", "pcm_s16be"), ("opus", "libopus")] {
            let source = directory.appendingPathComponent("audio '$ ` name." + ext)
            try await Command.run(tools.ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "sine=frequency=523:duration=4:sample_rate=48000",
                "-ac", "2", "-metadata", "title=Original title", "-c:a", codec, source.path])
            let original = try Data(contentsOf: source)
            let file = try await tools.inspect(source)
            let start = file.snapped(0.8), end = file.snapped(3.1)
            let output = file.suggestedURL
            try await tools.export(file, start: start, end: end, to: output)
            XCTAssertEqual(try Data(contentsOf: source), original, "Source changed: \(ext)")
            let exported = try await tools.inspect(output)
            XCTAssertEqual(exported.codec, file.codec)
            XCTAssertEqual(exported.channels, 2)
            XCTAssertEqual(exported.sampleRate, file.sampleRate)
            let maxPacket = zip(file.boundaries, file.boundaries.dropFirst()).map { $1 - $0 }.max() ?? 0.1
            XCTAssertEqual(exported.duration, end - start, accuracy: maxPacket * 2 + 0.01, "Wrong duration: \(ext)")
            // Compare actual packet payloads, not just codec labels. WAV/AIFF demuxers regroup raw samples.
            if !["wav", "aiff", "flac"].contains(ext) {
                let inputHashes = try await hashes(tools, source)
                let outputHashes = try await hashes(tools, output)
                XCTAssertFalse(outputHashes.isEmpty)
                if let index = inputHashes.firstIndex(of: outputHashes.first ?? "") {
                    XCTAssertEqual(Array(inputHashes.dropFirst(index).prefix(outputHashes.count)), outputHashes, "Audio re-encoded: \(ext)")
                } else { XCTFail("Output packet not found in source: \(ext)") }
            } else {
                let rawSource = try await Command.run(tools.ffmpeg, ["-v", "error", "-i", source.path, "-f", "s16le", "-c:a", "pcm_s16le", "-"])
                let rawOutput = try await Command.run(tools.ffmpeg, ["-v", "error", "-i", output.path, "-f", "s16le", "-c:a", "pcm_s16le", "-"])
                XCTAssertNotNil(rawSource.range(of: rawOutput), "PCM samples changed: \(ext)")
            }
            // Decoding must not report corrupt packets after a cut.
            try await Command.run(tools.ffmpeg, ["-v", "error", "-xerror", "-i", output.path, "-f", "null", "-"])
        }
    }

    func testExportFailuresAndOverwrite() async throws {
        guard let tools = FFmpegTools.locate() else { throw XCTSkip("FFmpeg is not installed") }
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.m4a")
        try await Command.run(tools.ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "sine=duration=2", "-c:a", "aac", source.path])
        let file = try await tools.inspect(source)
        let original = try Data(contentsOf: source)
        do {
            try await tools.export(file, start: 0, end: file.snapped(1), to: source)
            XCTFail("Overwrote without approval")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: source), original)
        do {
            try await tools.export(file, start: 1, end: 0, to: file.suggestedURL)
            XCTFail("Accepted inverted selection")
        } catch {}
        do {
            try await tools.export(file, start: 0, end: file.snapped(1), to: directory.appendingPathComponent("bad.mp3"))
            XCTFail("Accepted changed extension")
        } catch {}
        try await tools.export(file, start: 0, end: file.snapped(1), to: source, overwrite: true)
        XCTAssertNotEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".trimmer-") })
    }

    func testWaveformHasRealSilenceAndSound() async throws {
        guard let tools = FFmpegTools.locate() else { throw XCTSkip("FFmpeg is not installed") }
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("wave.wav")
        try await Command.run(tools.ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "aevalsrc=if(lt(t\\,1)\\,0\\,0.5*sin(2*PI*440*t)):s=44100:d=2", source.path])
        let file = try await tools.inspect(source)
        let peaks = try await tools.waveform(for: file, in: directory)
        XCTAssertLessThan(peaks.prefix(peaks.count / 3).max() ?? 1, 0.001)
        XCTAssertGreaterThan(peaks.suffix(peaks.count / 3).max() ?? 0, 0.4)
    }

    func testCancellationDoesNotFinishCommand() async throws {
        let task = Task { try await Command.run(URL(fileURLWithPath: "/bin/sleep"), ["20"]) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do { _ = try await task.value; XCTFail("Command ignored cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testArtworkAndTitleSurviveTrimming() async throws {
        guard let tools = FFmpegTools.locate() else { throw XCTSkip("FFmpeg is not installed") }
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cover = directory.appendingPathComponent("cover.png")
        try await Command.run(tools.ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "color=red:s=32x32", "-frames:v", "1", cover.path])
        let source = directory.appendingPathComponent("cover.m4a")
        try await Command.run(tools.ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "sine=duration=4", "-i", cover.path,
            "-map", "0:a", "-map", "1:v", "-c:a", "aac", "-c:v", "copy", "-disposition:v", "attached_pic",
            "-metadata", "title=Keep this title", source.path])
        let file = try await tools.inspect(source)
        XCTAssertTrue(file.hasArtwork)
        try await tools.export(file, start: file.snapped(1), end: file.snapped(3), to: file.suggestedURL)
        let result = try await tools.inspect(file.suggestedURL)
        XCTAssertTrue(result.hasArtwork)
        let metadata = try await Command.run(tools.ffprobe, ["-v", "error", "-show_entries", "format_tags=title", "-of", "json", file.suggestedURL.path])
        XCTAssertTrue(String(decoding: metadata, as: UTF8.self).contains("Keep this title"))
        let extractedCover = try await Command.run(tools.ffmpeg, ["-v", "error", "-i", file.suggestedURL.path, "-map", "0:v:0", "-c", "copy", "-f", "image2pipe", "-"])
        XCTAssertEqual(extractedCover, try Data(contentsOf: cover))
    }

    func testFLACRenumberingAcrossHeaderLengths() async throws {
        guard let tools = FFmpegTools.locate() else { throw XCTSkip("FFmpeg is not installed") }
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("long.flac")
        try await Command.run(tools.ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "sine=duration=32:sample_rate=48000", "-c:a", "flac", source.path])
        let file = try await tools.inspect(source)
        let start = file.snapped(14), end = file.snapped(31.7)
        try await tools.export(file, start: start, end: end, to: file.suggestedURL)
        let result = try await tools.inspect(file.suggestedURL)
        XCTAssertEqual(result.duration, end - start, accuracy: 0.000001)
        let expected = try await Command.run(tools.ffmpeg, ["-v", "error", "-i", source.path, "-ss", String(start), "-t", String(end - start), "-f", "s16le", "-"])
        let actual = try await Command.run(tools.ffmpeg, ["-v", "error", "-xerror", "-i", file.suggestedURL.path, "-f", "s16le", "-"])
        XCTAssertEqual(actual, expected)
    }

    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TrimmerTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func hashes(_ tools: FFmpegTools, _ url: URL) async throws -> [String] {
        let data = try await Command.run(tools.ffprobe, ["-v", "error", "-select_streams", "a:0", "-show_packets", "-show_data_hash", "sha256",
            "-show_entries", "packet=data_hash", "-of", "json", url.path])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["packets"] as? [[String: Any]])?.compactMap { $0["data_hash"] as? String } ?? []
    }
}
