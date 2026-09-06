import AppKit
import TrimmerCore

@MainActor
final class Dependencies: ObservableObject {
    @Published var tools: FFmpegTools?
    @Published var checking = true
    @Published var installing = false
    @Published var stage = "Benodigdheden controleren…"
    @Published var detail = ""
    @Published var failure: String?
    @Published var log = ""

    var brew: URL? {
        (["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] +
         (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/brew" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    func check() async {
        checking = true
        defer { checking = false }
        if let found = FFmpegTools.locate() {
            do {
                try await Command.run(found.ffmpeg, ["-version"])
                try await Command.run(found.ffprobe, ["-version"])
                tools = found
            } catch { failure = "FFmpeg is gevonden, maar start niet. \(error.localizedDescription)" }
        }
    }

    func install() async {
        guard !installing else { return }
        installing = true; failure = nil; log = ""
        defer { installing = false }
        do {
            if brew == nil { try await installHomebrew() }
            guard let brew else { throw CommandFailure("Homebrew is na installatie niet gevonden.") }
            stage = "FFmpeg installeren"
            detail = "Homebrew downloadt FFmpeg en de bijbehorende onderdelen. Dit kan enkele minuten duren."
            let path = brew.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
            try await Command.run(brew, ["install", "ffmpeg"], environment: [
                "PATH": path, "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1",
                "HOMEBREW_NO_ENV_HINTS": "1", "NONINTERACTIVE": "1"
            ], onProgress: { [weak self] output in
                Task { @MainActor [weak self] in self?.append(output) }
            })
            stage = "Installatie controleren"
            await check()
            guard tools != nil else { throw CommandFailure("FFmpeg of ffprobe ontbreekt nog. Controleer het installatielog en probeer opnieuw.") }
        } catch { failure = error.localizedDescription }
    }

    private func append(_ output: String) {
        log = String((log + output).suffix(16_000))
    }

    private func installHomebrew() async throws {
        stage = "Homebrew voorbereiden"
        detail = "Het officiële installatieprogramma opent Terminal. Vul daar zo nodig uw Mac-wachtwoord in en bevestig de installatie."
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Trimmer-install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let installer = directory.appendingPathComponent("install.sh")
        let status = directory.appendingPathComponent("status")
        let pid = directory.appendingPathComponent("pid")
        let logfile = directory.appendingPathComponent("install.log")
        let script = directory.appendingPathComponent("Installeer Homebrew.command")
        // Download before launch so a network failure is reported in the app.
        try await Command.run(URL(fileURLWithPath: "/usr/bin/curl"), ["--fail", "--location", "--proto", "=https",
            "--connect-timeout", "30", "--max-time", "180", "--output", installer.path,
            "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"])
        let content = """
        #!/bin/bash
        umask 077
        echo $$ > \(shellQuote(pid.path))
        trap 'echo 130 > \(shellQuote(status.path))' HUP INT TERM
        echo 'Trimmer — Homebrew installeren'
        /bin/bash \(shellQuote(installer.path)) 2>&1 | /usr/bin/tee \(shellQuote(logfile.path))
        result=${PIPESTATUS[0]}
        echo "$result" > \(shellQuote(status.path))
        echo 'U kunt dit Terminal-venster sluiten en teruggaan naar Trimmer.'
        exit "$result"
        """
        try content.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try await Command.run(URL(fileURLWithPath: "/usr/bin/open"), ["-a", "Terminal", script.path])
        stage = "Homebrew installeren"
        let began = Date()
        while !FileManager.default.fileExists(atPath: status.path) {
            try await Task.sleep(for: .milliseconds(500))
            if let text = try? String(contentsOf: logfile, encoding: .utf8) { log = String(text.suffix(16_000)) }
            if let value = try? String(contentsOf: pid, encoding: .utf8), let number = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)),
               kill(number, 0) != 0, errno == ESRCH {
                throw CommandFailure("De Homebrew-installatie is onderbroken. Probeer opnieuw.")
            }
            if Date().timeIntervalSince(began) > 7200 {
                throw CommandFailure("De installatie duurt langer dan verwacht. Controleer Terminal en kies daarna ‘Opnieuw controleren’.")
            }
        }
        let code = try String(contentsOf: status, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        if let text = try? String(contentsOf: logfile, encoding: .utf8) { log = String(text.suffix(16_000)) }
        try? FileManager.default.removeItem(at: directory)
        guard code == "0" else { throw CommandFailure("Homebrew is niet geïnstalleerd. Bekijk de melding in Terminal of het installatielog.") }
    }
}

private func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
