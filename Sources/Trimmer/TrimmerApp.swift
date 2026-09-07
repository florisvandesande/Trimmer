import SwiftUI

@main
struct TrimmerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = EditorModel()

    var body: some Scene {
        Window("Trimmer", id: "main") {
            ContentView(model: model, dependencies: model.dependencies)
                .onAppear {
                    delegate.model = model
                    delegate.fileOpenHandler = { [weak model] url in model?.open(url) }
                    #if DEBUG
                    delegate.runPreviewIfRequested()
                    #endif
                }
        }
        .defaultSize(width: 900, height: 200)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open audio…") { model.chooseFile() }.keyboardShortcut("o")
                    .disabled(model.exporting)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Kort in en bewaar…") { model.save() }.keyboardShortcut("s")
                    .disabled(!model.hasTrim || model.exporting)
            }
            CommandMenu("Afspelen") {
                Button(model.isPlaying ? "Pauzeer" : "Speel af") { model.togglePlayback() }
                    .keyboardShortcut(.space, modifiers: []).disabled(!model.canPlay || model.exporting)
                Button("Eén seconde terug") { model.seek(model.position - 1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("Eén seconde vooruit") { model.seek(model.position + 1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Divider()
                Button("Herstel selectie") { model.reset() }.keyboardShortcut("0").disabled(model.exporting)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: EditorModel?
    var fileOpenHandler: ((URL) -> Void)? {
        didSet {
            guard let fileOpenHandler, let pendingOpenURL else { return }
            self.pendingOpenURL = nil
            fileOpenHandler(pendingOpenURL)
        }
    }
    private var pendingOpenURL: URL?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let fileOpenHandler {
            fileOpenHandler(url)
        } else {
            pendingOpenURL = url
        }
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
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.exporting == true || model?.dependencies.installing == true {
            let alert = NSAlert()
            alert.messageText = "Er is nog een bewerking bezig"
            alert.informativeText = "Wacht tot de bewerking is afgerond voordat u Trimmer sluit."
            alert.addButton(withTitle: "Terug naar Trimmer")
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}
