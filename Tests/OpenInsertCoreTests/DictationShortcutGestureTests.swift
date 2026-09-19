import XCTest
@testable import OpenInsertCore

final class DictationShortcutGestureTests: XCTestCase {
    func testQuickTapUsesPhysicalTimesEvenWhenBothCallbacksArriveLate() {
        var gesture = DictationShortcutGesture()
        // These two historical event timestamps can arrive after a two-second UI stall.
        // The processing clock is deliberately absent from the gesture API.
        XCTAssertEqual(gesture.press(at: 100, phase: .idle), .start)
        XCTAssertEqual(gesture.release(at: 100.10, phase: .recording), .none)
        XCTAssertEqual(gesture.press(at: 105, phase: .recording), .finish)
        XCTAssertEqual(gesture.release(at: 106, phase: .recording), .none)
    }

    func testLongHoldFinishesOnlyWhenReleased() {
        var gesture = DictationShortcutGesture()
        XCTAssertEqual(gesture.press(at: 100, phase: .idle), .start)
        XCTAssertEqual(gesture.release(at: 100.5, phase: .recording), .finish)
        XCTAssertEqual(gesture.release(at: 101, phase: .recording), .none)
    }

    func testHeldReleaseDuringPreparationFinishesWhenReady() {
        var gesture = DictationShortcutGesture()
        XCTAssertEqual(gesture.press(at: 20, phase: .idle), .start)
        XCTAssertEqual(gesture.release(at: 21, phase: .preparing), .finishWhenReady)
    }

    func testSecondTapDuringPreparationFinishesWhenReady() {
        var gesture = DictationShortcutGesture()
        XCTAssertEqual(gesture.press(at: 20, phase: .idle), .start)
        XCTAssertEqual(gesture.release(at: 20.1, phase: .preparing), .none)
        XCTAssertEqual(gesture.press(at: 21, phase: .preparing), .finishWhenReady)
        XCTAssertEqual(gesture.release(at: 22, phase: .recording), .none)
    }

    func testBusyAndResetCannotLeaveAStaleHeldGesture() {
        var gesture = DictationShortcutGesture()
        XCTAssertEqual(gesture.press(at: 10, phase: .busy), .none)
        XCTAssertEqual(gesture.release(at: 20, phase: .recording), .none)
        XCTAssertEqual(gesture.press(at: 30, phase: .idle), .start)
        gesture.reset()
        XCTAssertEqual(gesture.release(at: 40, phase: .recording), .none)
        XCTAssertEqual(gesture.press(at: 50, phase: .idle), .start)
        XCTAssertEqual(gesture.release(at: 60, phase: .busy), .none)
        XCTAssertEqual(gesture.release(at: 61, phase: .recording), .none)
    }

    func testInvalidAndReversedTimestampsDoNotFinishRecording() {
        var gesture = DictationShortcutGesture()
        XCTAssertEqual(gesture.press(at: .nan, phase: .idle), .none)
        XCTAssertEqual(gesture.press(at: 10, phase: .idle), .start)
        XCTAssertEqual(gesture.release(at: 9, phase: .recording), .none)
        XCTAssertEqual(gesture.press(at: 20, phase: .idle), .start)
        XCTAssertEqual(gesture.release(at: .infinity, phase: .recording), .none)
        XCTAssertEqual(gesture.release(at: 21, phase: .recording), .none)
    }
}
