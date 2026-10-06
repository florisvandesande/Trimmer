import AppKit
import SwiftUI

@main
struct TrimmerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var windows = EditorWindows.shared

    var body: some Scene {
        WindowGroup("Trimmer", id: "bootstrap") {
            BootstrapWindowView()
        }
        Settings { AnalysisSettingsView() }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Over Trimmer") { showAboutPanel() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open audio…") {
                    if let model = windows.activeModel { model.chooseFile() }
                    else { windows.open(); windows.activeModel?.chooseFile() }
                }.keyboardShortcut("o")
                Button("Sluit venster") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w")
            }
            EditorCommands(model: windows.activeModel)
        }
    }

    private func showAboutPanel() {
        let credits = NSMutableAttributedString(string: "Gebouwd door ruimtegever.\n\n")
        let starText = NSAttributedString(
            string: "Bevalt Trimmer? Geef het project een ster op GitHub.",
            attributes: [
                .link: URL(string: "https://github.com/florisvandesande/Trimmer")!,
                .foregroundColor: NSColor.linkColor
            ]
        )
        credits.append(starText)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

private struct BootstrapWindowView: NSViewRepresentable {
    func makeNSView(context: Context) -> BootstrapWindowHost {
        BootstrapWindowHost()
    }

    func updateNSView(_ nsView: BootstrapWindowHost, context: Context) {}
}

private final class BootstrapWindowHost: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.window?.close()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: EditorModel? { EditorWindows.shared.activeModel }
    var fileOpenHandler: ((URL) -> Void)? {
        didSet {
            guard let fileOpenHandler else { return }
            let pending = pendingOpenURLs; pendingOpenURLs = []
            pending.forEach(fileOpenHandler)
        }
    }
    private var pendingOpenURLs: [URL] = []
    func application(_ application: NSApplication, open urls: [URL]) {
        if let fileOpenHandler { urls.forEach(fileOpenHandler) }
        else { pendingOpenURLs.append(contentsOf: urls) }
    }

    #if DEBUG
    private var previewStarted = false
    /// Deterministic rendering of the actual native window for local visual verification.
    func runPreviewIfRequested() {
        let args = CommandLine.arguments
        guard !previewStarted, let index = args.firstIndex(of: "--snapshot"), args.count > index + 1 else { return }
        previewStarted = true
        Task {
            guard let model else { return }
            await model.dependencies.check()
            if let fileIndex = args.firstIndex(of: "--preview-file"), args.count > fileIndex + 1 {
                model.open(URL(fileURLWithPath: args[fileIndex + 1]))
                for _ in 0..<600 {
                    if !model.loading && !model.waveformLoading { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if let audio = model.audio {
                    model.setStart(audio.duration * 0.1)
                    model.setEnd(audio.duration * 0.88)
                    model.seek(audio.duration * 0.36)
                }
            }
            try? await Task.sleep(for: .seconds(1))
            guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible }),
                  let view = window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: args[index + 1]))
            }
            NSApp.terminate(nil)
        }
    }
    #endif
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        fileOpenHandler = { EditorWindows.shared.open($0) }
        if EditorWindows.shared.editors.isEmpty { EditorWindows.shared.open() }
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        runPreviewIfRequested()
        #endif
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { EditorWindows.shared.open() }
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !EditorWindows.shared.terminating else { return .terminateCancel }
        Task { sender.reply(toApplicationShouldTerminate: await EditorWindows.shared.confirmTermination()) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        for editor in EditorWindows.shared.editors { editor.model.shutdown() }
    }
}

struct EditorCommands: Commands {
    let model: EditorModel?
    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            if let model { SaveCommand(model: model) }
        }
        CommandMenu("Afspelen") {
            if let model { PlaybackCommands(model: model) }
        }
        CommandMenu("Golfvorm") {
            if let model { ZoomCommands(model: model) }
        }
    }
}

private struct SaveCommand: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        Button("Kort in en bewaar…") { model.save() }.keyboardShortcut("s")
            .disabled(!model.hasTrim || !model.canTrim || model.exporting || model.closeLocked)
    }
}

private struct PlaybackCommands: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        Button(model.isPlaying ? "Pauzeer" : "Speel af") { model.togglePlayback() }
            .keyboardShortcut(.space, modifiers: []).disabled(!model.canPlay || model.exporting || model.closeLocked)
        Button("Eén seconde terug") { model.seek(model.position - 1) }.keyboardShortcut(.leftArrow, modifiers: [])
        Button("Eén seconde vooruit") { model.seek(model.position + 1) }.keyboardShortcut(.rightArrow, modifiers: [])
        Divider()
        Button("Herstel selectie") { model.reset() }.keyboardShortcut("0").disabled(model.exporting || model.closeLocked)
    }
}

private struct ZoomCommands: View {
    @ObservedObject var model: EditorModel
    var body: some View {
            Button("Zoom in") { model.zoom(2) }.keyboardShortcut("+", modifiers: .command)
                .disabled(model.audio == nil)
            Button("Zoom uit") { model.zoom(0.5) }.keyboardShortcut("-", modifiers: .command)
                .disabled(model.audio == nil)
            Button("Toon volledige golfvorm") { model.showAll() }.keyboardShortcut("0", modifiers: [.command, .shift])
                .disabled(model.audio == nil)
    }
}
