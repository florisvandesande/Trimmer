import AppKit
import AVFoundation
import UniformTypeIdentifiers
import TrimmerCore
import Combine

@MainActor
final class EditorModel: ObservableObject {
    @Published var audio: AudioFile?
    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published var position: Double = 0
    @Published var isPlaying = false
    @Published var loading = false
    @Published var waveformLoading = false
    @Published var exporting = false
    @Published var closeLocked = false
    @Published var exportProgress = 0.0
    @Published var error: String?
    @Published var savedURL: URL?
    @Published var loadingMessage = "Audio openen…"
    @Published var canPlay = false
    let dependencies: Dependencies
    @Published var waveform = Waveform(peaks: [])
    @Published var repeats: [RepeatRegion] = []
    @Published var visibleStart = 0.0
    @Published var visibleDuration = 0.0
    var requestOpen: ((URL) -> Void)?
    private var analysis: AudioAnalysis?
    private var repeatTask: Task<Void, Never>?
    private var repeatGeneration = UUID()
    private var settingsSubscription: AnyCancellable?
    private let analysisSettings: AnalysisSettings
    private var savedSelection: (Double, Double)?
    var canTrim: Bool { !(audio?.boundaries.isEmpty ?? true) }
    var isDirty: Bool {
        guard let audio else { return false }
        let baseline = savedSelection ?? (0, audio.duration)
        return abs(start - baseline.0) > 0.000001 || abs(end - baseline.1) > 0.000001
    }
    var viewDuration: Double { visibleDuration > 0 ? visibleDuration : (audio?.duration ?? 1) }
    func zoom(_ factor: Double, anchor: Double = 0.5) {
        guard let audio, factor.isFinite, factor > 0 else { return }
        let fraction = min(1, max(0, anchor))
        let time = visibleStart + viewDuration * fraction
        visibleDuration = min(audio.duration, max(min(1, audio.duration), viewDuration / factor))
        visibleStart = min(max(0, time - visibleDuration * fraction), max(0, audio.duration - visibleDuration))
    }
    func scroll(_ seconds: Double) {
        guard let audio else { return }
        visibleStart = min(max(0, visibleStart + seconds), max(0, audio.duration - viewDuration))
    }
    func showAll() { visibleStart = 0; visibleDuration = audio?.duration ?? 0 }
    func markSaved() { savedSelection = (start, end) }
    func openRequested(_ url: URL) {
        if let requestOpen { requestOpen(url) } else { open(url) }
    }
    private var workspace: URL?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var pendingURL: URL?
    var hasPendingOpen: Bool { pendingURL != nil }
    private var generation = UUID()
    private var hasPositionedPlayhead = false
    private var isTrimming = false

    var selectionDuration: Double { end - start }
    var hasTrim: Bool { audio.map { start > 0 || end < $0.duration } ?? false }

    init(dependencies: Dependencies? = nil, settings: AnalysisSettings? = nil) {
        self.dependencies = dependencies ?? Dependencies()
        analysisSettings = settings ?? AnalysisSettings.shared
        settingsSubscription = analysisSettings.$minimumDuration
            .combineLatest(analysisSettings.$recognitionEnabled)
            .dropFirst()
            .sink { [weak self] minimum, enabled in
                self?.startRepeatAnalysis(minimum: minimum, enabled: enabled)
            }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Kies een audiobestand om begin en einde in te korten."
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { Task { @MainActor in self?.openRequested(url) } }
        }
    }

    func open(_ url: URL) {
        guard !exporting else { return }
        guard let tools = dependencies.tools else { pendingURL = url; return }
        guard url.isFileURL else { error = "Kies een lokaal audiobestand."; return }
        cancelLoading()
        let token = UUID(); generation = token
        player = nil; canPlay = false; audio = nil; savedURL = nil
        savedSelection = nil; repeats = []; analysis = nil; waveform = Waveform(peaks: [])
        visibleStart = 0; visibleDuration = 0
        loading = true; waveformLoading = false; loadingMessage = "Audiobestand analyseren…"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Trimmer-" + token.uuidString)
        workspace = directory
        loadTask = Task {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = try await tools.metadata(url)
                try Task.checkCancellation()
                guard generation == token else { return }
                audio = file; start = 0; end = file.duration; position = 0
                visibleDuration = file.duration
                loading = false; waveformLoading = true
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.loadBoundaries(file, tools: tools, token: token) }
                    group.addTask { await self.loadPlayback(file, tools: tools, directory: directory, token: token) }
                    group.addTask { await self.loadAnalysis(file, tools: tools, token: token) }
                }
            } catch {
                guard generation == token else { return }
                loading = false; waveformLoading = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    private func loadBoundaries(_ file: AudioFile, tools: FFmpegTools, token: UUID) async {
        do {
            let indexed = try await tools.indexed(file)
            try Task.checkCancellation()
            guard generation == token else { return }
            audio = indexed
        } catch { if generation == token && !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func loadPlayback(_ file: AudioFile, tools: FFmpegTools, directory: URL, token: UUID) async {
        do {
            let prepared: AVAudioPlayer
            do { prepared = try AVAudioPlayer(contentsOf: file.url) }
            catch {
                let url = try await tools.playbackCopy(for: file, in: directory)
                try Task.checkCancellation()
                prepared = try AVAudioPlayer(contentsOf: url)
            }
            try Task.checkCancellation()
            guard generation == token else { return }
            prepared.prepareToPlay(); player = prepared; canPlay = true
        } catch { if generation == token && !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func loadAnalysis(_ file: AudioFile, tools: FFmpegTools, token: UUID) async {
        do {
            let result = try await tools.analyze(file, progress: { [weak self] waveform in
                Task { @MainActor in
                    guard let self, self.generation == token, self.waveformLoading else { return }
                    self.waveform = waveform
                }
            })
            try Task.checkCancellation()
            guard generation == token else { return }
            analysis = result; waveform = result.waveform; waveformLoading = false
            startRepeatAnalysis()
        } catch {
            guard generation == token else { return }
            waveformLoading = false
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }

    private func startRepeatAnalysis(minimum requestedMinimum: Double? = nil, enabled requestedEnabled: Bool? = nil) {
        repeatTask?.cancel(); repeatGeneration = UUID(); repeats = []
        guard requestedEnabled ?? analysisSettings.recognitionEnabled, let analysis else { return }
        let token = repeatGeneration
        let minimum = requestedMinimum ?? analysisSettings.minimumDuration
        repeatTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let result = try RepeatDetector.detect(analysis, minimumDuration: minimum, progress: { regions in
                    Task { @MainActor [weak self] in
                        guard let self, self.repeatGeneration == token else { return }
                        self.repeats = regions
                    }
                })
                await MainActor.run { [weak self] in
                    guard let self, self.repeatGeneration == token else { return }
                    self.repeats = result
                    self.repeatGeneration = UUID()
                }
            } catch { /* Cancellation and inconclusive detection do not interrupt editing. */ }
        }
    }

    func openPending() {
        if let url = pendingURL { pendingURL = nil; open(url) }
    }

    func cancelLoading() {
        cancelProcessing()
        generation = UUID(); repeatGeneration = UUID()
        hasPositionedPlayhead = false; isTrimming = false
        pause(); player = nil; canPlay = false; loading = false; waveformLoading = false; audio = nil
        pendingURL = nil; analysis = nil; repeats = []; waveform = Waveform(peaks: [])
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
        guard let audio, canTrim, !closeLocked, !exporting else { return }
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
        guard let audio, canTrim, !closeLocked, !exporting else { return }
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
        if let width = timelineWidth, width.isFinite, width > 0 {
            var targets: [Double] = []
            if hasPositionedPlayhead, position > 0 { targets.append(position) }
            targets.append(contentsOf: repeats.flatMap(\.edges))
            var nearest: Double?
            var distance = Double.infinity
            for point in targets {
                let target = audio.snapped(point)
                let pixels = abs(value - point) / viewDuration * width
                if pixels <= 6, pixels < distance, isStart ? target < end : target > start {
                    nearest = target; distance = pixels
                }
            }
            if let nearest { return nearest }
        }
        return audio.snapped(value)
    }

    func reset() {
        guard let audio, !closeLocked, !exporting else { return }
        pause(); start = 0; end = audio.duration; movePlayhead(to: 0); savedURL = nil
        hasPositionedPlayhead = false; isTrimming = false
    }

    private func tick() {
        guard isPlaying, let player else { return }
        position = player.currentTime
        if position >= end || !player.isPlaying { pause(); movePlayhead(to: end) }
    }

    func save(completion: @escaping (Bool) -> Void = { _ in }) {
        guard let audio, let tools = dependencies.tools, canTrim, !exporting else { completion(false); return }
        pause()
        let selection = (start, end)
        exporting = true
        let panel = NSSavePanel()
        panel.title = "Ingekorte audio bewaren"
        panel.nameFieldStringValue = audio.suggestedURL.lastPathComponent
        panel.directoryURL = audio.url.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let type = UTType(filenameExtension: audio.url.pathExtension) { panel.allowedContentTypes = [type] }
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { self?.exporting = false; completion(false); return }
            Task { @MainActor in
                guard let self else { completion(false); return }
                let overwrite = FileManager.default.fileExists(atPath: destination.path)
                self.exporting = true; self.exportProgress = 0; self.savedURL = nil
                self.exportTask = Task {
                    defer { self.exporting = false }
                    do {
                        try await tools.export(audio, start: selection.0, end: selection.1, to: destination, overwrite: overwrite,
                            progress: { value in Task { @MainActor in self.exportProgress = value } })
                        self.savedURL = destination
                        self.savedSelection = selection
                        if destination.resolvingSymlinksInPath() == audio.url.resolvingSymlinksInPath() {
                            self.exporting = false
                            self.open(destination)
                            self.savedURL = destination
                        }
                        self.exporting = false
                        completion(true)
                    } catch {
                        if !(error is CancellationError) { self.error = error.localizedDescription }
                        self.exporting = false; completion(false)
                    }
                }
            }
        }
    }

    func cancelExport() { exportTask?.cancel() }

    private func cancelProcessing() {
        let task = loadTask
        task?.cancel(); repeatTask?.cancel()
        loadTask = nil; repeatTask = nil
        let directory = workspace; workspace = nil
        Task {
            await task?.value
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
    }

    func shutdownAndWait() async {
        let loadingTask = loadTask, detectionTask = repeatTask, savingTask = exportTask
        let directory = workspace
        shutdown()
        await loadingTask?.value
        await detectionTask?.value
        await savingTask?.value
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func shutdown() {
        pause(); generation = UUID(); repeatGeneration = UUID()
        cancelProcessing(); exportTask?.cancel(); timer?.invalidate()
    }
}

func timeLabel(_ seconds: Double, precise: Bool = true) -> String {
    let millis = Int((max(0, seconds) * 1000).rounded())
    let hours = millis / 3_600_000, minutes = (millis / 60_000) % 60, wholeSeconds = (millis / 1000) % 60
    let base = hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, wholeSeconds) : String(format: "%02d:%02d", minutes, wholeSeconds)
    return precise ? base + String(format: ".%03d", millis % 1000) : base
}
