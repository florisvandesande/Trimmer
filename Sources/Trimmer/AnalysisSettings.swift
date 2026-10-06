import SwiftUI

@MainActor
final class AnalysisSettings: ObservableObject {
    static let shared = AnalysisSettings()
    @Published private(set) var minimumDuration: Double
    @Published private(set) var recognitionEnabled: Bool
    init(defaults: UserDefaults = .standard) {
        let value = defaults.double(forKey: "repeatMinimumDuration")
        minimumDuration = value.isFinite && value >= 1 ? value : 30
        recognitionEnabled = defaults.object(forKey: "repeatRecognitionEnabled") as? Bool ?? true
        self.defaults = defaults
    }
    private let defaults: UserDefaults
    func save(_ value: Double) {
        guard value.isFinite, value >= 1, value != minimumDuration else { return }
        defaults.set(value, forKey: "repeatMinimumDuration")
        minimumDuration = value
    }
    func setRecognitionEnabled(_ enabled: Bool) {
        guard enabled != recognitionEnabled else { return }
        defaults.set(enabled, forKey: "repeatRecognitionEnabled")
        recognitionEnabled = enabled
    }
}

struct AnalysisSettingsView: View {
    @ObservedObject var settings = AnalysisSettings.shared
    @State private var value = ""
    @State private var saved = false
    @FocusState private var editingDuration: Bool
    private var number: Double? { Double(value.replacingOccurrences(of: ",", with: ".")) }
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "waveform")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(trimYellow)
                .frame(width: 56, height: 56)
                .background(trimYellow.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
                .accessibilityHidden(true)

            Toggle("Herhalingen herkennen", isOn: Binding(
                get: { settings.recognitionEnabled },
                set: { settings.setRecognitionEnabled($0) }
            ))
            .toggleStyle(.switch)
            .font(.system(size: 15, weight: .semibold))
            .tint(trimYellow)
            .fixedSize()

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Text("Minimumduur")
                    TextField("", text: $value)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .padding(.vertical, 7)
                        .frame(width: 64)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(editingDuration ? trimYellow.opacity(0.7) : .white.opacity(0.1)))
                        .focused($editingDuration)
                        .accessibilityLabel("Minimumduur in seconden")
                    Text("seconden")
                }
                .font(.system(size: 13))
                .disabled(!settings.recognitionEnabled)
                .opacity(settings.recognitionEnabled ? 1 : 0.4)

                Text("Geldt voor alle audio bestanden.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(saved ? "Bewaard" : "Bewaar") {
                if let number { settings.save(number); saved = true; editingDuration = false }
            }
            .buttonStyle(YellowButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!settings.recognitionEnabled || (number.map { !$0.isFinite || $0 < 1 } ?? true))
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .frame(width: 420)
        .background(Color(red: 0.085, green: 0.088, blue: 0.092))
        .preferredColorScheme(.dark)
        .onAppear { value = String(format: "%g", settings.minimumDuration) }
        .onChange(of: value) { _ in saved = false }
    }
}
