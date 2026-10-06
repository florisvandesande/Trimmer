import AppKit
import SwiftUI
import Combine

@MainActor
final class EditorWindows: ObservableObject {
    static let shared = EditorWindows()
    @Published var activeModel: EditorModel?
    let dependencies = Dependencies()
    private(set) var editors: [EditorWindowController] = []
    var terminating = false

    func open(_ url: URL? = nil) {
        guard !terminating else { return }
        if let empty = editors.first(where: { $0.model.audio == nil && !$0.model.loading && !$0.model.hasPendingOpen }) {
            empty.showWindow(nil); empty.window?.makeKeyAndOrderFront(nil)
            if let url { empty.model.open(url) }
            return
        }
        let model = EditorModel(dependencies: dependencies)
        model.requestOpen = { [weak self] url in self?.open(url) }
        let controller = EditorWindowController(model: model, coordinator: self)
        editors.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        activeModel = model
        if let url { model.open(url) }
    }

    func remove(_ controller: EditorWindowController) {
        editors.removeAll { $0 === controller }
        if activeModel === controller.model { activeModel = editors.last?.model }
    }

    func confirmTermination() async -> Bool {
        guard !terminating else { return false }
        terminating = true
        defer { terminating = false }
        if let busy = editors.first(where: { $0.model.exporting || $0.model.dependencies.installing }) {
            return await busy.confirmClose()
        }
        let approved = await CloseWorkflow.confirmAll(editors.map(\.model)) { model in
            guard let editor = self.editors.first(where: { $0.model === model }) else { return true }
            return await editor.confirmClose()
        }
        guard approved else { return false }
        for editor in editors { editor.model.closeLocked = true }
        for editor in editors { await editor.model.shutdownAndWait() }
        return true
    }
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: EditorModel
    weak var coordinator: EditorWindows?
    private var titleSubscription: AnyCancellable?
    private var closing = false
    private var prompting = false
    init(model: EditorModel, coordinator: EditorWindows) {
        self.model = model; self.coordinator = coordinator
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Trimmer"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model, dependencies: model.dependencies))
        window.delegate = self
        titleSubscription = model.$audio.sink { [weak window] audio in
            window?.title = audio?.url.lastPathComponent ?? "Trimmer"
            window?.representedURL = audio?.url
        }
        window.center()
        window.setFrameAutosaveName("TrimmerEditor")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowDidBecomeKey(_ notification: Notification) { coordinator?.activeModel = model }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing { return true }
        guard coordinator?.terminating != true, !prompting else { return false }
        Task {
            if await confirmClose() { closing = true; sender.close() }
        }
        return false
    }
    func windowWillClose(_ notification: Notification) { model.shutdown(); coordinator?.remove(self) }

    func confirmClose() async -> Bool {
        guard !prompting else { return false }
        if model.exporting || model.dependencies.installing {
            let alert = NSAlert()
            alert.messageText = "Er is nog een bewerking bezig"
            alert.informativeText = "Wacht tot de bewerking is afgerond voordat u dit venster sluit."
            alert.addButton(withTitle: "Terug naar Trimmer")
            if let window { await alert.beginSheetModal(for: window) }
            return false
        }
        guard model.isDirty else { return true }
        prompting = true
        let wasLocked = model.closeLocked
        model.closeLocked = true
        defer { prompting = false; model.closeLocked = wasLocked }
        model.pause()
        window?.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "Wijzigingen bewaren?"
        alert.informativeText = "Wilt u de trimselectie voor ‘\(model.audio?.url.lastPathComponent ?? "audio")’ bewaren?"
        alert.addButton(withTitle: "Bewaar")
        alert.addButton(withTitle: "Niet bewaren")
        alert.addButton(withTitle: "Annuleer").keyEquivalent = "\u{1b}"
        guard let window else { return false }
        let response = await alert.beginSheetModal(for: window)
        switch response {
        case .alertFirstButtonReturn:
            return await withCheckedContinuation { continuation in
                model.save { continuation.resume(returning: $0) }
            }
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
}

/// Freeze all selections while individual save decisions are collected. No window is
/// closed before the last decision, so cancellation leaves the entire session open.
@MainActor
enum CloseWorkflow {
    static func confirmAll(_ models: [EditorModel], confirm: (EditorModel) async -> Bool) async -> Bool {
        guard !models.contains(where: { $0.exporting || $0.dependencies.installing }) else { return false }
        for model in models { model.closeLocked = true }
        defer { for model in models { model.closeLocked = false } }
        for model in models where model.isDirty {
            guard await confirm(model) else { return false }
        }
        return true
    }
}
