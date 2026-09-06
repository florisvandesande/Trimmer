import Foundation

/// Native FLAC stores sample/frame positions inside each frame. Stream copy alone leaves
/// those positions and STREAMINFO's total sample count pointing at the original file.
/// Rewrites framing and checksums only; the compressed subframes are copied byte for byte.
enum FLACRepair {
    static func repair(_ url: URL, tools: FFmpegTools) async throws {
        let data = try await Command.run(tools.ffprobe, ["-v", "error", "-select_streams", "a:0", "-show_packets",
            "-show_entries", "packet=pos,size", "-of", "json", url.path])
        struct Packets: Decodable {
            struct Packet: Decodable { let pos: String; let size: String }
            let packets: [Packet]
        }
        let packets = try JSONDecoder().decode(Packets.self, from: data).packets
        guard !packets.isEmpty else { throw CommandFailure("De FLAC-selectie bevat geen audio.") }
        let temporary = url.appendingPathExtension("repair")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        guard try input.read(upToCount: 4) == Data("fLaC".utf8) else { throw invalid() }
        var metadata: [(UInt8, Data)] = []
        while true {
            guard let head = try input.read(upToCount: 4), head.count == 4 else { throw invalid() }
            let length = Int(head[1]) << 16 | Int(head[2]) << 8 | Int(head[3])
            guard let body = try input.read(upToCount: length), body.count == length else { throw invalid() }
            let kind = head[0] & 0x7f
            // Seek offsets and cue times describe the original timeline.
            if kind != 3 && kind != 5 { metadata.append((kind, body)) }
            if head[0] & 0x80 != 0 { break }
        }
        guard metadata.first?.0 == 0, metadata.first?.1.count == 34 else { throw invalid() }
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        try output.write(contentsOf: Data("fLaC".utf8))
        for (index, block) in metadata.enumerated() {
            let length = block.1.count
            try output.write(contentsOf: Data([block.0 | (index == metadata.count - 1 ? 0x80 : 0),
                                               UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)]))
            try output.write(contentsOf: block.1)
        }
        var samples: UInt64 = 0
        var minimum = Int.max, maximum = 0
        for (index, packet) in packets.enumerated() {
            try Task.checkCancellation()
            guard let position = UInt64(packet.pos), let size = Int(packet.size), size >= 8 else { throw invalid() }
            try input.seek(toOffset: position)
            guard let data = try input.read(upToCount: size), data.count == size else { throw invalid() }
            var frame = [UInt8](data)
            guard frame[0] == 0xff, frame[1] & 0xfe == 0xf8 else { throw invalid() }
            let variable = frame[1] & 1 == 1
            let numberLength = utf8Length(frame[4])
            guard numberLength > 0, 4 + numberLength < frame.count - 2 else { throw invalid() }
            var headerEnd = 4 + numberLength
            let code = Int(frame[2] >> 4)
            let blockSamples: Int
            switch code {
            case 1: blockSamples = 192
            case 2...5: blockSamples = 576 << (code - 2)
            case 6:
                guard headerEnd < frame.count - 3 else { throw invalid() }
                blockSamples = Int(frame[headerEnd]) + 1; headerEnd += 1
            case 7:
                guard headerEnd + 1 < frame.count - 3 else { throw invalid() }
                blockSamples = (Int(frame[headerEnd]) << 8 | Int(frame[headerEnd + 1])) + 1; headerEnd += 2
            case 8...15: blockSamples = 256 << (code - 8)
            default: throw invalid()
            }
            switch frame[2] & 15 {
            case 12: headerEnd += 1
            case 13, 14: headerEnd += 2
            default: break
            }
            guard headerEnd < frame.count - 2, crc8(frame[0..<headerEnd]) == frame[headerEnd],
                  crc16(frame.dropLast(2)) == UInt16(frame[frame.count - 2]) << 8 | UInt16(frame[frame.count - 1]) else { throw invalid() }
            var header = Array(frame.prefix(4)) + encodeUTF8(variable ? samples : UInt64(index))
            header += frame[(4 + numberLength)..<headerEnd]
            header.append(crc8(header[...]))
            frame = header + frame[(headerEnd + 1)..<(frame.count - 2)]
            let crc = crc16(frame[...])
            frame += [UInt8(crc >> 8), UInt8(crc & 255)]
            try output.write(contentsOf: Data(frame))
            samples += UInt64(blockSamples)
            minimum = min(minimum, frame.count); maximum = max(maximum, frame.count)
        }
        guard samples < 1 << 36 else { throw invalid() }
        var info = [UInt8](metadata[0].1)
        for (offset, value) in [(4, minimum), (7, maximum)] {
            info[offset] = UInt8((value >> 16) & 255); info[offset + 1] = UInt8((value >> 8) & 255); info[offset + 2] = UInt8(value & 255)
        }
        info[13] = (info[13] & 0xf0) | UInt8((samples >> 32) & 15)
        for index in 0..<4 { info[14 + index] = UInt8((samples >> ((3 - index) * 8)) & 255) }
        // An all-zero MD5 explicitly means unknown; the original checksum is no longer valid.
        for index in 18..<34 { info[index] = 0 }
        try output.seek(toOffset: 8)
        try output.write(contentsOf: Data(info))
        try output.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw invalid() }
    }

    private static func invalid() -> CommandFailure { CommandFailure("De FLAC-headers konden niet veilig worden bijgewerkt. Het origineel is behouden.") }
    private static func utf8Length(_ byte: UInt8) -> Int {
        if byte < 0x80 { return 1 }
        var count = 0, mask: UInt8 = 0x80
        while byte & mask != 0 && mask > 0 { count += 1; mask >>= 1 }
        return (2...7).contains(count) ? count : 0
    }
    private static func encodeUTF8(_ value: UInt64) -> [UInt8] {
        if value < 128 { return [UInt8(value)] }
        var length = 2
        while length < 7 && value >= UInt64(1) << (5 * length + 1) { length += 1 }
        var bytes = [UInt8](repeating: 0, count: length)
        var rest = value
        for index in (1..<length).reversed() { bytes[index] = 0x80 | UInt8(rest & 0x3f); rest >>= 6 }
        bytes[0] = UInt8((0xff << (8 - length)) & 255) | UInt8(rest)
        return bytes
    }
    private static func crc8(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc &<< 1) ^ 0x07 : crc &<< 1 }
        }
        return crc
    }
    private static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc &<< 1) ^ 0x8005 : crc &<< 1 }
        }
        return crc
    }
}
