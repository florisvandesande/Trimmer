import SwiftUI
import UniformTypeIdentifiers
import TrimmerCore

struct ContentView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var dependencies: Dependencies
    @State private var dragTarget = false

    var body: some View {
        VStack(spacing: 0) {
            if dependencies.checking && !dependencies.installing {
                Spacer(); ProgressView("Benodigdheden controleren…"); Spacer()
            } else if dependencies.tools == nil {
                DependencyView(dependencies: dependencies)
            } else if model.loading {
                Spacer()
                ProgressView(model.loadingMessage)
                Button("Annuleren") { model.cancelLoading() }.buttonStyle(.plain).padding(.top, 16)
                Spacer()
            } else if let audio = model.audio {
                HStack(spacing: 0) {
                    VStack(spacing: 8) {
                        TimelineView(model: model, audio: audio)
                            .coordinateSpace(name: "trimTimeline")
                        transport
                            .padding(.horizontal, 14)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .disabled(model.exporting)

                    Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
                    sidebar(for: audio)
                }
            } else {
                emptyState
            }
        }
        .frame(minWidth: 800, maxWidth: .infinity,
               minHeight: contentHeight, maxHeight: contentHeight)
        .background(Color(red: 0.085, green: 0.088, blue: 0.092))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dragTarget ? trimYellow : .clear, lineWidth: 2))
        .preferredColorScheme(.dark)
        .onDrop(of: [.fileURL], isTargeted: $dragTarget) { providers in
            guard !model.exporting, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.open(url) } }
            }
            return true
        }
        .alert("Dit is niet gelukt", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .task { await dependencies.check(); model.openPending() }
        .onChange(of: dependencies.tools != nil) { ready in if ready { model.openPending() } }
    }

    private var contentHeight: CGFloat {
        dependencies.tools == nil && !dependencies.checking ? 420 : 200
    }

    private var transport: some View {
        HStack(alignment: .center) {
            timeBlock("BEGIN", value: model.start, action: { model.pause(); model.seek(model.start) })
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .offset(x: model.isPlaying ? 0 : 1)
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.08), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.06)))
                }
                .keyboardShortcut(.space, modifiers: [])
                .help("Afspelen of pauzeren (spatiebalk)")
                .accessibilityLabel(model.isPlaying ? "Pauzeren" : "Afspelen")
                Text(timeLabel(model.position, precise: false))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel("Huidige tijd: " + timeLabel(model.position, precise: false))
            }
            .buttonStyle(.plain).disabled(!model.canPlay)
            Spacer(minLength: 12)
            timeBlock("EINDE", value: model.end, action: { model.pause(); model.seek(model.end) })
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            HStack(spacing: 22) {
                Image(systemName: "waveform")
                    .font(.system(size: 26, weight: .light)).foregroundStyle(trimYellow)
                    .frame(width: 56, height: 56)
                    .background(trimYellow.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
                VStack(alignment: .leading, spacing: 8) {
                    Text("Alleen het geluid dat u wilt houden.").font(.system(size: 18, weight: .semibold))
                    Text("Sleep een audiobestand naar dit venster.\nKort het begin en einde in, zonder kwaliteitsverlies.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                }
            }
            Button("Kies een audiobestand…") { model.chooseFile() }
                .buttonStyle(YellowButtonStyle())
            Text("Het oorspronkelijke bestand blijft standaard behouden.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sidebar(for audio: AudioFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(audio.url.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2).truncationMode(.middle)
                        .help(audio.url.path)
                    if let saved = model.savedURL {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([saved]) } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.green.opacity(0.9))
                        }
                        .buttonStyle(.plain)
                        .help("Bewaard · Toon in Finder: " + saved.lastPathComponent)
                        .accessibilityLabel("Bewaard. Toon in Finder")
                    }
                }
                Text("\(audio.codec.uppercased())  ·  \(String(format: "%.1f", Double(audio.sampleRate) / 1000)) kHz  ·  \(audio.channels == 1 ? "Mono" : audio.channels == 2 ? "Stereo" : "\(audio.channels) kanalen")")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Oorspronkelijke duur: " + timeLabel(audio.duration))
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("DUUR").font(.system(size: 8, weight: .semibold))
                    .tracking(0.7).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(timeLabel(model.selectionDuration))
                    .font(.system(size: 19, weight: .medium, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityLabel("Nieuwe duur: " + timeLabel(model.selectionDuration))
            }

            Spacer(minLength: 0)

            if model.exporting {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Audio bewaren…").font(.system(size: 11))
                    ProgressView(value: model.exportProgress).tint(trimYellow)
                }
                Button("Annuleren") { model.cancelExport() }
                    .buttonStyle(.plain).font(.system(size: 12))
            } else {
                VStack(spacing: 6) {
                    Button { model.save() } label: {
                        Text("Kort in en bewaar…").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(YellowButtonStyle()).disabled(!model.hasTrim)
                    .keyboardShortcut("s")
                    Button { model.reset() } label: {
                        Text("Herstel").font(.system(size: 11))
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).disabled(!model.hasTrim)
                }
            }
        }
        .padding(12)
        .frame(width: 184)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.13))
    }

    private func timeBlock(_ title: String, value: Double, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: title == "BEGIN" ? .leading : .trailing, spacing: 4) {
                Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary)
                Text(timeLabel(value)).font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            .frame(width: 94, alignment: title == "BEGIN" ? .leading : .trailing)
        }.buttonStyle(.plain)
    }
}

struct YellowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(isEnabled ? Color.black.opacity(0.88) : Color.white.opacity(0.25))
            .background(isEnabled ? trimYellow.opacity(configuration.isPressed ? 0.8 : 1) : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8))
    }
}

struct DependencyView: View {
    @ObservedObject var dependencies: Dependencies
    @State private var showLog = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 12)
            Image(systemName: "arrow.down.circle").font(.system(size: 30, weight: .light)).foregroundStyle(trimYellow)
            Text(dependencies.installing ? dependencies.stage : "Eenmalig voorbereiden")
                .font(.system(size: 22, weight: .semibold))
            Text(dependencies.installing ? dependencies.detail :
                 "Trimmer gebruikt FFmpeg om audio zonder hercodering in te korten. We installeren het via Homebrew. Als Homebrew ontbreekt, wordt dat eerst geïnstalleerd; Terminal kan om uw Mac-wachtwoord vragen.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            if dependencies.installing {
                ProgressView().progressViewStyle(.linear).tint(trimYellow)
            }
            if let failure = dependencies.failure {
                Text(failure).font(.system(size: 12)).foregroundStyle(.red).lineLimit(5).textSelection(.enabled)
            }
            if !dependencies.installing {
                HStack(spacing: 16) {
                    Button("Installeer benodigdheden") { Task { await dependencies.install() } }.buttonStyle(YellowButtonStyle())
                    Button("Opnieuw controleren") { Task { await dependencies.check() } }.buttonStyle(.plain)
                }
            }
            if !dependencies.log.isEmpty {
                DisclosureGroup("Installatielog", isExpanded: $showLog) {
                    ScrollView {
                        Text(dependencies.log).font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 95)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
        }.padding(.horizontal, 64).frame(maxWidth: 730)
    }
}
