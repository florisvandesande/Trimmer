import Foundation
import Darwin

extension FFmpegTools {
    /// Decoding is for display only. Export never uses these samples.
    public func waveform(for audio: AudioFile, in workspace: URL) async throws -> [Float] {
        let raw = workspace.appendingPathComponent("waveform.f32")
        defer { try? FileManager.default.removeItem(at: raw) }
        try await Command.run(ffmpeg, ["-v", "error", "-nostdin", "-i", audio.url.path,
            "-map", "0:a:0", "-vn", "-ar", "8000", "-c:a", "pcm_f32le", "-f", "f32le", "-"], outputFile: raw)
        return try await Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forReadingFrom: raw)
            defer { try? handle.close() }
            let bins = min(24_000, max(600, Int(audio.duration * 100)))
            let attributes = try FileManager.default.attributesOfItem(atPath: raw.path)
            let sampleCount = max(1, (attributes[.size] as? NSNumber)?.intValue ?? 0) / 4
            var peaks = [Float](repeating: 0, count: bins)
            var offset = 0
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                chunk.withUnsafeBytes { bytes in
                    for index in stride(from: 0, to: bytes.count - 3, by: 4) {
                        let value = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: index, as: UInt32.self)))
                        let bin = min(bins - 1, offset * bins / max(1, sampleCount))
                        if value.isFinite { peaks[bin] = max(peaks[bin], abs(value)) }
                        offset += 1
                    }
                }
            }
            return peaks
        }.value
    }

    public func playbackCopy(for audio: AudioFile, in workspace: URL) async throws -> URL {
        let output = workspace.appendingPathComponent("preview.caf")
        try await Command.run(ffmpeg, ["-v", "error", "-nostdin", "-y", "-i", audio.url.path,
            "-map", "0:a:0", "-vn", "-c:a", "pcm_s16le", output.path])
        return output
    }

    /// All encoded audio packets are copied, never encoded or filtered.
    /// Commit happens only after successful export and verification, on the same filesystem.
    public func export(_ audio: AudioFile, start: Double, end: Double, to destination: URL,
                       overwrite: Bool = false,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard start.isFinite, end.isFinite, start >= 0, end <= audio.duration + 0.000001, end > start,
              abs(audio.snapped(start) - start) < 0.000001, abs(audio.snapped(end) - end) < 0.000001 else {
            throw CommandFailure("De selectie heeft geen geldige knippunten.")
        }
        guard destination.pathExtension.lowercased() == audio.url.pathExtension.lowercased() else {
            throw CommandFailure("Behoud de oorspronkelijke bestandsextensie om zonder conversie op te slaan.")
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path), !overwrite {
            throw CommandFailure("Er bestaat al een bestand met deze naam.")
        }
        let directory = destination.deletingLastPathComponent().appendingPathComponent(".trimmer-" + UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("output." + destination.pathExtension)
        let length = end - start
        // Output-side seeking discards earlier packets instead of retaining an earlier seek point.
        let args = ["-v", "error", "-nostdin", "-i", audio.url.path,
                    "-ss", String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), start),
                    "-t", String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), length),
                    "-map", "0:a:0", "-map_metadata", "0", "-map_chapters", "-1",
                    "-c", "copy", "-avoid_negative_ts", "make_zero", "-progress", "pipe:1", "-nostats", temporary.path]
        try await Command.run(ffmpeg, args, onProgress: { text in
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                if let value = Double(line.dropFirst("out_time_us=".count)) {
                    progress?(min(0.98, max(0, value / 1_000_000 / length)))
                }
            }
        })
        try Task.checkCancellation()
        // Output seeking drops artwork at timestamp zero. Attach it in a second copy-only
        // mux so the cover survives a nonzero start without altering the selected audio.
        if audio.hasArtwork {
            let withArtwork = directory.appendingPathComponent("artwork." + destination.pathExtension)
            try await Command.run(ffmpeg, ["-v", "error", "-nostdin", "-i", temporary.path, "-i", audio.url.path,
                "-map", "0:a:0", "-map", "1:v", "-map_metadata", "0", "-map_chapters", "-1",
                "-c", "copy", "-disposition:v", "attached_pic", withArtwork.path])
            guard rename(withArtwork.path, temporary.path) == 0 else {
                throw CommandFailure("De albumafbeelding kon niet worden behouden.")
            }
        }
        if audio.codec == "flac", destination.pathExtension.lowercased() == "flac" {
            try await FLACRepair.repair(temporary, tools: self)
        }
        let check = try await Command.run(ffprobe, ["-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=codec_name,sample_rate,channels", "-of", "json", temporary.path])
        let object = try JSONSerialization.jsonObject(with: check) as? [String: Any]
        guard let streams = object?["streams"] as? [[String: Any]], let stream = streams.first,
              stream["codec_name"] as? String == audio.codec,
              stream["sample_rate"] as? String == String(audio.sampleRate),
              stream["channels"] as? Int == audio.channels,
              ((try manager.attributesOfItem(atPath: temporary.path)[.size]) as? NSNumber)?.intValue ?? 0 > 0 else {
            throw CommandFailure("Het opgeslagen audiobestand kon niet worden gecontroleerd. Het origineel is behouden.")
        }
        try Task.checkCancellation()
        if overwrite {
            guard rename(temporary.path, destination.path) == 0 else {
                throw CommandFailure("Het bestand kon niet worden vervangen: \(String(cString: strerror(errno)))")
            }
        } else {
            // Exclusive move: a file created after the save dialog is never silently replaced.
            try manager.moveItem(at: temporary, to: destination)
        }
        progress?(1)
    }
}
