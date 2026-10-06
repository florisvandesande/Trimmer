import XCTest
import TrimmerCore
@testable import Trimmer

@MainActor
final class SettingsAndTimelineTests: XCTestCase {
    func testUntouchedEndpointsRemainVisibleAtEveryZoomAndWidth() {
        // Fractional durations and zoom factors reproduce a coordinate slightly
        // larger than width even when scrolled exactly to the file endpoint.
        for length in [630.163265306, 626.177729, 10.1, 7200.123456] {
            for zoom in [1.1, 1.7, 2, 3, 7.3, 10, 111.17, 600] {
                let span = max(1, length / zoom)
                for width in [551.0, 667.0, 701.5, 1000.0] {
                    let right = TimelineGeometry(start: length - span, duration: span, width: width)
                    XCTAssertEqual(right.x(for: length), width)
                    XCTAssertTrue(right.contains(right.x(for: length)))
                    let left = TimelineGeometry(start: 0, duration: span, width: width)
                    XCTAssertEqual(left.x(for: 0), 0)
                    XCTAssertTrue(left.contains(left.x(for: 0)))
                }
            }
        }
        let interior = TimelineGeometry(start: 10, duration: 2, width: 667)
        XCTAssertFalse(interior.contains(interior.x(for: 12.001)))
        XCTAssertFalse(interior.contains(interior.x(for: 9.999)))
        XCTAssertEqual(interior.x(for: 11), 333.5)
    }

    func testRecognitionPreferenceDefaultsOnAndPersistsIndependentlyOfDuration() {
        let name = "TrimmerSettingsTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AnalysisSettings(defaults: defaults)
        XCTAssertTrue(settings.recognitionEnabled)
        settings.save(45)
        settings.setRecognitionEnabled(false)
        let restored = AnalysisSettings(defaults: defaults)
        XCTAssertFalse(restored.recognitionEnabled)
        XCTAssertEqual(restored.minimumDuration, 45)
        restored.setRecognitionEnabled(true)
        XCTAssertTrue(AnalysisSettings(defaults: defaults).recognitionEnabled)
    }

    func testRecognitionToggleUpdatesAllEditorsAndRejectsLateResults() async throws {
        guard let tools = FFmpegTools.locate() else { throw XCTSkip("FFmpeg is required") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("repeated.wav")
        try await Command.run(tools.ffmpeg, ["-v", "error", "-f", "lavfi", "-i",
            "anoisesrc=color=pink:amplitude=0.4:sample_rate=8000:duration=4:seed=42",
            "-af", "aloop=loop=1:size=32000", file.path])
        let name = "TrimmerToggleTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AnalysisSettings(defaults: defaults)
        settings.save(1); settings.setRecognitionEnabled(false)
        let dependencies = Dependencies()
        dependencies.tools = tools; dependencies.checking = false
        let a = EditorModel(dependencies: dependencies, settings: settings)
        let b = EditorModel(dependencies: dependencies, settings: settings)
        let c = EditorModel(dependencies: dependencies, settings: settings)
        defer { a.shutdown(); b.shutdown(); c.shutdown() }
        a.open(file); b.open(file)
        try await waitUntil { a.audio != nil && b.audio != nil && !a.waveformLoading && !b.waveformLoading }
        XCTAssertTrue(a.repeats.isEmpty && b.repeats.isEmpty)
        settings.setRecognitionEnabled(true)
        try await waitUntil { !a.repeats.isEmpty && !b.repeats.isEmpty }
        settings.setRecognitionEnabled(false)
        XCTAssertTrue(a.repeats.isEmpty && b.repeats.isEmpty)
        c.open(file)
        try await waitUntil { c.audio != nil && !c.waveformLoading }
        XCTAssertTrue(c.repeats.isEmpty)
        settings.setRecognitionEnabled(true)
        settings.setRecognitionEnabled(false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(a.repeats.isEmpty && b.repeats.isEmpty && c.repeats.isEmpty)
        settings.setRecognitionEnabled(true)
        try await waitUntil { !a.repeats.isEmpty && !b.repeats.isEmpty && !c.repeats.isEmpty }
        XCTAssertFalse(a.isDirty || b.isDirty || c.isDirty)
        await a.shutdownAndWait(); await b.shutdownAndWait(); await c.shutdownAndWait()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Timed out waiting for audio analysis")
        if !condition() { throw NSError(domain: "TrimmerTests", code: 1) }
    }
}
