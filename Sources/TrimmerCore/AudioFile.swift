import Foundation

public struct AudioFile: Sendable {
    public let url: URL
    public let duration: Double
    public let codec: String
    public let sampleRate: Int
    public let channels: Int
    public let boundaries: [Double]
    public let hasArtwork: Bool

    public init(url: URL, duration: Double, codec: String, sampleRate: Int,
                channels: Int, boundaries: [Double], hasArtwork: Bool = false) {
        self.url = url; self.duration = duration; self.codec = codec
        self.sampleRate = sampleRate; self.channels = channels; self.boundaries = boundaries
        self.hasArtwork = hasArtwork
    }

    public func snapped(_ time: Double) -> Double {
        let time = min(duration, max(0, time))
        var lower = 0, upper = boundaries.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if boundaries[middle] < time { lower = middle + 1 } else { upper = middle }
        }
        if lower == 0 { return boundaries.first ?? 0 }
        if lower == boundaries.count { return boundaries.last ?? duration }
        return time - boundaries[lower - 1] < boundaries[lower] - time ? boundaries[lower - 1] : boundaries[lower]
    }

    public var suggestedURL: URL {
        url.deletingLastPathComponent().appendingPathComponent(
            url.deletingPathExtension().lastPathComponent + "-trimmed." + url.pathExtension)
    }
}

public struct FFmpegTools: Sendable {
    public let ffmpeg: URL
    public let ffprobe: URL
    public init(ffmpeg: URL, ffprobe: URL) { self.ffmpeg = ffmpeg; self.ffprobe = ffprobe }

    public static func locate() -> FFmpegTools? {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin"] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        for path in paths where !path.isEmpty {
            let root = URL(fileURLWithPath: path)
            let ffmpeg = root.appendingPathComponent("ffmpeg"), ffprobe = root.appendingPathComponent("ffprobe")
            if FileManager.default.isExecutableFile(atPath: ffmpeg.path),
               FileManager.default.isExecutableFile(atPath: ffprobe.path) {
                return FFmpegTools(ffmpeg: ffmpeg, ffprobe: ffprobe)
            }
        }
        return nil
    }

    public func inspect(_ url: URL) async throws -> AudioFile {
        let data = try await Command.run(ffprobe, ["-v", "error", "-show_streams", "-show_format", "-of", "json", url.path])
        let result = try JSONDecoder().decode(Probe.self, from: data)
        let audioStreams = result.streams.filter { $0.codec_type == "audio" }
        guard audioStreams.count == 1, let stream = audioStreams.first else {
            throw CommandFailure("Kies een bestand met één audiospoor.")
        }
        guard !result.streams.contains(where: { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 }) else {
            throw CommandFailure("Trimmer ondersteunt audiobestanden. Dit bestand bevat video.")
        }
        guard let duration = Double(stream.duration ?? result.format.duration ?? ""), duration.isFinite, duration > 0 else {
            throw CommandFailure("De lengte van dit audiobestand kon niet worden gelezen.")
        }
        let origin = Double(result.format.start_time ?? "0") ?? 0
        let packets = try await Command.run(ffprobe, ["-v", "error", "-select_streams", "a:0", "-show_packets",
            "-show_entries", "packet=pts_time", "-of", "csv=p=0", url.path])
        let boundaries = String(decoding: packets, as: UTF8.self).split(separator: "\n").compactMap { line -> Double? in
            guard let first = line.split(separator: ",").first, let pts = Double(first) else { return nil }
            let time = pts - origin
            return time > 0 && time < duration && time.isFinite ? time : nil
        }
        guard !boundaries.isEmpty else { throw CommandFailure("Geen bruikbare knippunten gevonden in dit bestand.") }
        return AudioFile(url: url, duration: duration, codec: stream.codec_name ?? "audio",
                         sampleRate: Int(stream.sample_rate ?? "0") ?? 0, channels: stream.channels ?? 1,
                         boundaries: [0] + Array(Set(boundaries)).sorted() + [duration],
                         hasArtwork: result.streams.contains { $0.codec_type == "video" && $0.disposition?["attached_pic"] == 1 })
    }
}

private struct Probe: Decodable {
    struct Stream: Decodable {
        let codec_type: String?
        let codec_name: String?
        let duration: String?
        let sample_rate: String?
        let channels: Int?
        let disposition: [String: Int]?
    }
    struct Format: Decodable { let duration: String?; let start_time: String? }
    let streams: [Stream]
    let format: Format
}
