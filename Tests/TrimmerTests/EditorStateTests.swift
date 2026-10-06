import XCTest
import TrimmerCore
@testable import Trimmer

@MainActor
final class EditorStateTests: XCTestCase {
    private func editor() -> EditorModel {
        let model = EditorModel()
        model.audio = AudioFile(url: URL(fileURLWithPath: "/tmp/state.wav"), duration: 100, codec: "pcm_s16le",
                                sampleRate: 48000, channels: 2, boundaries: (0...10000).map { Double($0) / 100 })
        model.end = 100; model.visibleDuration = 100
        return model
    }
    func testDirtyBaselinePlaybackZoomResetAndSave() {
        let model = editor(); defer { model.shutdown() }
        XCTAssertFalse(model.isDirty)
        model.seek(20); model.zoom(2); model.scroll(10)
        XCTAssertFalse(model.isDirty)
        model.setStart(5); XCTAssertTrue(model.isDirty)
        model.reset(); XCTAssertFalse(model.isDirty)
        model.setEnd(80); model.markSaved(); XCTAssertFalse(model.isDirty)
        model.setStart(4); XCTAssertTrue(model.isDirty)
        model.setStart(0); XCTAssertFalse(model.isDirty)
    }
    func testZoomAnchorAndScrollBounds() {
        let model = editor(); defer { model.shutdown() }
        model.zoom(4, anchor: 0.8)
        XCTAssertEqual(model.viewDuration, 25)
        XCTAssertEqual(model.visibleStart, 60)
        model.scroll(1000); XCTAssertEqual(model.visibleStart, 75)
        model.scroll(-1000); XCTAssertEqual(model.visibleStart, 0)
        model.zoom(1000); XCTAssertEqual(model.viewDuration, 1)
        model.showAll(); XCTAssertEqual(model.viewDuration, 100); XCTAssertEqual(model.visibleStart, 0)
    }
    func testRepeatMagnetUsesVisibleScaleAndCannotCollapseSelection() {
        let model = editor(); defer { model.shutdown() }
        model.repeats = [RepeatRegion(originalStart: 5, repeatedStart: 50, duration: 30)]
        model.zoom(10)
        model.setStart(49.95, timelineWidth: 1000); XCTAssertEqual(model.start, 50)
        model.setStart(49.9, timelineWidth: 1000); XCTAssertEqual(model.start, 49.9)
        model.setEnd(80.05, timelineWidth: 1000); XCTAssertEqual(model.end, 80)
        model.setStart(79.99, timelineWidth: 1000); XCTAssertLessThan(model.start, model.end)
    }
    func testEditorsAreIndependentAndSettingsPersist() {
        let a = editor(), b = editor(); defer { a.shutdown(); b.shutdown() }
        a.setStart(20); a.zoom(2)
        XCTAssertEqual(b.start, 0); XCTAssertEqual(b.viewDuration, 100); XCTAssertFalse(b.isDirty)
        let name = "TrimmerTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AnalysisSettings(defaults: defaults)
        XCTAssertEqual(settings.minimumDuration, 30)
        settings.save(5)
        XCTAssertEqual(AnalysisSettings(defaults: defaults).minimumDuration, 5)
        settings.save(0); settings.save(.infinity)
        XCTAssertEqual(settings.minimumDuration, 5)
    }
    func testQuitAsksIndividuallyAndCancellationKeepsAllEditors() async {
        let a = editor(), b = editor(), untouched = editor()
        defer { a.shutdown(); b.shutdown(); untouched.shutdown() }
        a.setStart(1); b.setEnd(90)
        var asked: [EditorModel] = []
        let approved = await CloseWorkflow.confirmAll([a, b, untouched]) { model in
            asked.append(model)
            XCTAssertTrue(a.closeLocked && b.closeLocked)
            if model === a { model.markSaved(); return true }
            return false
        }
        XCTAssertFalse(approved)
        XCTAssertEqual(asked.count, 2)
        XCTAssertTrue(asked[0] === a && asked[1] === b)
        XCTAssertNotNil(a.audio); XCTAssertNotNil(b.audio)
        XCTAssertFalse(a.isDirty); XCTAssertTrue(b.isDirty)
        XCTAssertFalse(a.closeLocked || b.closeLocked)
        var next: [EditorModel] = []
        let retried = await CloseWorkflow.confirmAll([a, b, untouched]) { model in
            next.append(model); return true
        }
        XCTAssertTrue(retried); XCTAssertEqual(next.count, 1); XCTAssertTrue(next[0] === b)
    }

    func testQuitRefusesActiveExportAndLocksSelectionsDuringQuestions() async {
        let model = editor(); defer { model.shutdown() }
        model.setStart(5); model.exporting = true
        let blocked = await CloseWorkflow.confirmAll([model]) { _ in XCTFail("Must wait for export"); return true }
        XCTAssertFalse(blocked)
        model.exporting = false
        let approved = await CloseWorkflow.confirmAll([model]) { model in
            model.setStart(10); model.reset()
            XCTAssertEqual(model.start, 5)
            return true
        }
        XCTAssertTrue(approved)
    }

}
