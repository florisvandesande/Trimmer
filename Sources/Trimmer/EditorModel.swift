import AppKit
import AVFoundation
import UniformTypeIdentifiers
import TrimmerCore

@MainActor
final class EditorModel: ObservableObject {
    @Published var audio: AudioFile?
    @Published var peaks: [Float] = []
    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published var position: Double = 0
    @Published var isPlaying = false
    @Published var loading = false
    @Published var waveformLoading = false
    @Published var exporting = false
    @Published var exportProgress = 0.0
    @Published var error: String?
    @Published var savedURL: URL?
    @Published var loadingMessage = "Audio openen…"
    @Published var canPlay = false
    let dependencies = Dependencies()
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var workspace: URL?
    private var pendingURL: URL?
    private var generation = UUID()
    private var hasPositionedPlayhead = false
    private var isTrimming = false

    var selectionDuration: Double { end - start }
    var hasTrim: Bool { audio.map { start > 0 || end < $0.duration } ?? false }

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func chooseFile() {
        guard !exporting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Kies een audiobestand om begin en einde in te korten."
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { Task { @MainActor in self?.open(url) } }
        }
    }

    func open(_ url: URL) {
        guard !exporting else { return }
        guard let tools = dependencies.tools else { pendingURL = url; return }
        guard url.isFileURL else { error = "Kies een lokaal audiobestand."; return }
        pause(); loadTask?.cancel()
        hasPositionedPlayhead = false; isTrimming = false
        let token = UUID(); generation = token
        let oldWorkspace = workspace
        player = nil; canPlay = false; audio = nil; peaks = []; savedURL = nil
        loading = true; waveformLoading = false; loadingMessage = "Audiobestand analyseren…"
        loadTask = Task {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Trimmer-" + token.uuidString)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = try await tools.inspect(url)
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                workspace = directory
                audio = file; start = 0; end = file.duration; position = 0
                loading = false; waveformLoading = true
                // Native playback avoids generating a full decoded copy for common formats.
                do { player = try AVAudioPlayer(contentsOf: url) }
                catch {
                    loadingMessage = "Luistervoorbeeld voorbereiden…"
                    let preview = try await tools.playbackCopy(for: file, in: directory)
                    try Task.checkCancellation()
                    player = try AVAudioPlayer(contentsOf: preview)
                }
                player?.prepareToPlay(); canPlay = true
                let values = try await tools.waveform(for: file, in: directory)
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                peaks = values; waveformLoading = false
                if let oldWorkspace { try? FileManager.default.removeItem(at: oldWorkspace) }
            } catch {
                try? FileManager.default.removeItem(at: directory)
                if let oldWorkspace { try? FileManager.default.removeItem(at: oldWorkspace) }
                guard generation == token else { return }
                loading = false; waveformLoading = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    func openPending() {
        if let url = pendingURL { pendingURL = nil; open(url) }
    }

    func cancelLoading() {
        loadTask?.cancel(); generation = UUID()
        hasPositionedPlayhead = false; isTrimming = false
        pause(); player = nil; canPlay = false; loading = false; waveformLoading = false; audio = nil; peaks = []
    }

    func togglePlayback() {
        guard canPlay, let player else { return }
        if isPlaying { pause(); return }
        if position < start || position >= end - 0.005 { movePlayhead(to: start) }
        player.currentTime = position
        isPlaying = player.play()
        if isPlaying { hasPositionedPlayhead = true }
        if !isPlaying { error = "Dit bestand kon niet worden afgespeeld." }
    }

    func pause() { player?.pause(); isPlaying = false }

    func seek(_ value: Double) {
        guard audio != nil, value.isFinite else { return }
        movePlayhead(to: value)
        // Explicitly seeking back to zero restores the original follow-the-handle mode.
        hasPositionedPlayhead = position > 0
    }

    private func movePlayhead(to value: Double) {
        guard let audio else { return }
        position = min(audio.duration, max(0, value))
        player?.currentTime = position
    }

    func beginTrimming() {
        pause()
        if position == 0 { hasPositionedPlayhead = false }
        isTrimming = true
    }

    func endTrimming() { isTrimming = false }

    func setStart(_ value: Double, timelineWidth: Double? = nil) {
        guard let audio else { return }
        let standalone = !isTrimming
        if standalone { beginTrimming() }
        defer { if standalone { endTrimming() } }
        let snapped = trimPoint(value, audio: audio, timelineWidth: timelineWidth, isStart: true)
        guard snapped < end, snapped != start else { return }
        start = snapped
        if !hasPositionedPlayhead { movePlayhead(to: start) }
        savedURL = nil
    }

    func setEnd(_ value: Double, timelineWidth: Double? = nil) {
        guard let audio else { return }
        let standalone = !isTrimming
        if standalone { beginTrimming() }
        defer { if standalone { endTrimming() } }
        let snapped = trimPoint(value, audio: audio, timelineWidth: timelineWidth, isStart: false)
        guard snapped > start, snapped != end else { return }
        end = snapped
        if !hasPositionedPlayhead { movePlayhead(to: end) }
        savedURL = nil
    }

    private func trimPoint(_ value: Double, audio: AudioFile, timelineWidth: Double?, isStart: Bool) -> Double {
        if hasPositionedPlayhead, position > 0, let width = timelineWidth, width.isFinite, width > 0 {
            // Six screen points keeps the magnetic area visually narrow at any window size.
            let distance = abs(value - position) / audio.duration * width
            let target = audio.snapped(position)
            if distance <= 6, isStart ? target < end : target > start { return target }
        }
        return audio.snapped(value)
    }

    func reset() {
        guard let audio else { return }
        pause(); start = 0; end = audio.duration; movePlayhead(to: 0); savedURL = nil
        hasPositionedPlayhead = false; isTrimming = false
    }

    func previewEnd() { pause(); seek(max(start, end - 3)); togglePlayback() }

    private func tick() {
        guard isPlaying, let player else { return }
        position = player.currentTime
        if position >= end || !player.isPlaying { pause(); movePlayhead(to: end) }
    }

    func save() {
        guard let audio, let tools = dependencies.tools, hasTrim, !exporting else { return }
        pause()
        let panel = NSSavePanel()
        panel.title = "Ingekorte audio bewaren"
        panel.nameFieldStringValue = audio.suggestedURL.lastPathComponent
        panel.directoryURL = audio.url.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let type = UTType(filenameExtension: audio.url.pathExtension) { panel.allowedContentTypes = [type] }
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                let overwrite = FileManager.default.fileExists(atPath: destination.path)
                self.exporting = true; self.exportProgress = 0; self.savedURL = nil
                self.exportTask = Task {
                    defer { self.exporting = false }
                    do {
                        try await tools.export(audio, start: self.start, end: self.end, to: destination, overwrite: overwrite,
                            progress: { value in Task { @MainActor in self.exportProgress = value } })
                        self.savedURL = destination
                        if destination.resolvingSymlinksInPath() == audio.url.resolvingSymlinksInPath() {
                            self.exporting = false
                            self.open(destination)
                            self.savedURL = destination
                        }
                    } catch {
                        if !(error is CancellationError) { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }

    func cancelExport() { exportTask?.cancel() }

    func shutdown() {
        pause(); loadTask?.cancel(); exportTask?.cancel(); timer?.invalidate()
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
    }
}

func timeLabel(_ seconds: Double, precise: Bool = true) -> String {
    let millis = Int((max(0, seconds) * 1000).rounded())
    let hours = millis / 3_600_000, minutes = (millis / 60_000) % 60, wholeSeconds = (millis / 1000) % 60
    let base = hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, wholeSeconds) : String(format: "%02d:%02d", minutes, wholeSeconds)
    return precise ? base + String(format: ".%03d", millis % 1000) : base
}
