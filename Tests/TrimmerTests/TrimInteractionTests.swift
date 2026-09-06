import XCTest
import TrimmerCore
@testable import Trimmer

@MainActor
final class TrimInteractionTests: XCTestCase {
    private func editor() -> EditorModel {
        let model = EditorModel()
        model.audio = AudioFile(url: URL(fileURLWithPath: "/tmp/interaction.wav"), duration: 10,
                                codec: "pcm_s16le", sampleRate: 48000, channels: 2,
                                boundaries: (0...500).map { Double($0) / 50 })
        model.start = 0; model.end = 10
        return model
    }

    func testUntouchedPlayheadKeepsFollowingAcrossDrags() async {
        let model = editor(); defer { model.shutdown() }
        model.beginTrimming()
        model.setStart(1, timelineWidth: 1000)
        XCTAssertEqual(model.position, 1)
        model.setStart(2, timelineWidth: 1000)
        XCTAssertEqual(model.position, 2)
        model.endTrimming()
        model.setEnd(8, timelineWidth: 1000)
        XCTAssertEqual(model.position, 8)
    }

    func testPositionedPlayheadSurvivesGrabbingAndBothTrimHandles() async {
        let model = editor(); defer { model.shutdown() }
        model.seek(4.013)
        model.beginTrimming()
        XCTAssertEqual(model.position, 4.013)
        model.setStart(2, timelineWidth: 1000)
        model.endTrimming()
        model.setEnd(8, timelineWidth: 1000)
        XCTAssertEqual(model.position, 4.013)
        // Even excluding the playhead from the selection must not reposition it.
        model.setStart(6, timelineWidth: 1000)
        XCTAssertEqual(model.position, 4.013)
    }

    func testBothHandlesSnapToNearestPacketAtPlayhead() async {
        let model = editor(); defer { model.shutdown() }
        model.seek(4.013)
        model.setStart(3.97, timelineWidth: 1000)
        XCTAssertEqual(model.start, 4.02, accuracy: 0.000001)
        XCTAssertEqual(model.position, 4.013)
        model.setStart(2)
        model.setEnd(4.06, timelineWidth: 1000)
        XCTAssertEqual(model.end, 4.02, accuracy: 0.000001)
        XCTAssertEqual(model.position, 4.013)
    }

    func testMagnetReleasesBeyondSixPointsAndScalesWithWidth() async {
        let model = editor(); defer { model.shutdown() }
        model.seek(4)
        model.beginTrimming()
        model.setStart(3.96, timelineWidth: 1000)
        XCTAssertEqual(model.start, 4)
        model.setStart(3.92, timelineWidth: 1000)
        XCTAssertEqual(model.start, 3.92)
        model.endTrimming()
        // The same time difference is outside the magnetic area in a wider timeline.
        model.setStart(3.96, timelineWidth: 2000)
        XCTAssertEqual(model.start, 3.96)
        XCTAssertEqual(model.position, 4)
    }

    func testSeekingToZeroRestoresFollowingForWholeGesture() async {
        let model = editor(); defer { model.shutdown() }
        model.seek(4)
        model.seek(0)
        model.beginTrimming()
        model.setEnd(9, timelineWidth: 1000)
        model.setEnd(8, timelineWidth: 1000)
        XCTAssertEqual(model.position, 8)
        model.endTrimming()
        model.setStart(1, timelineWidth: 1000)
        XCTAssertEqual(model.position, 1)
    }

    func testExplicitSeekDuringTrimBecomesNewMagneticTarget() async {
        let model = editor(); defer { model.shutdown() }
        model.beginTrimming()
        model.setStart(1, timelineWidth: 1000)
        model.seek(5.013)
        model.setStart(3, timelineWidth: 1000)
        XCTAssertEqual(model.position, 5.013)
        model.setStart(4.97, timelineWidth: 1000)
        XCTAssertEqual(model.start, 5.02, accuracy: 0.000001)
        XCTAssertEqual(model.position, 5.013)
    }

    func testMagnetCannotCollapseSelection() async {
        let model = editor(); defer { model.shutdown() }
        model.setEnd(4)
        model.seek(4)
        model.setStart(3.96, timelineWidth: 1000)
        XCTAssertEqual(model.start, 3.96)
        XCTAssertEqual(model.end, 4)
        XCTAssertEqual(model.position, 4)
    }

    func testResetRestoresFollowingAndKeyboardStepsDoNotStick() async {
        let model = editor(); defer { model.shutdown() }
        model.seek(4)
        model.setStart(3.98)
        XCTAssertEqual(model.start, 3.98)
        XCTAssertEqual(model.position, 4)
        model.reset()
        model.setStart(1, timelineWidth: 1000)
        XCTAssertEqual(model.position, 1)
    }
}
