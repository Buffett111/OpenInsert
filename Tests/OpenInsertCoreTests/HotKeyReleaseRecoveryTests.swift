import XCTest
@testable import OpenInsertCore

final class HotKeyReleaseRecoveryTests: XCTestCase {
    func testAlreadyReleasedFirstSampleRemainsShortTapDespiteDeliveryDelay() {
        var state = HotKeyReleaseRecovery(pressedAt: 10)
        XCTAssertEqual(state.sample(isHeld: false, at: 12), 10)
        XCTAssertTrue(state.releaseIsUncertain)
    }

    func testInitialReleasedSampleNearPressIsAnUnambiguousShortTap() {
        var state = HotKeyReleaseRecovery(pressedAt: 10)
        XCTAssertEqual(state.sample(isHeld: false, at: 10.1), 10)
        XCTAssertFalse(state.releaseIsUncertain)
    }

    func testShortTapUsesConfirmedHeldTimeNotDelayedReleaseSample() {
        var state = HotKeyReleaseRecovery(pressedAt: 10)
        XCTAssertNil(state.sample(isHeld: true, at: 10.01))
        XCTAssertNil(state.sample(isHeld: true, at: 10.12))
        XCTAssertEqual(state.sample(isHeld: false, at: 12), 10.12)
        XCTAssertFalse(state.releaseIsUncertain)
    }

    func testHeldComboProducesLongReleaseAfterEitherRequiredKeyIsUp() {
        var state = HotKeyReleaseRecovery(pressedAt: 10)
        XCTAssertNil(state.sample(isHeld: true, at: 10.02))
        XCTAssertNil(state.sample(isHeld: true, at: 11.20))
        XCTAssertEqual(state.sample(isHeld: false, at: 11.22), 11.20)
        XCTAssertFalse(state.releaseIsUncertain)
    }

    func testReleaseCompletesOnlyOnceEvenIfCombinationIsPressedAgain() {
        var state = HotKeyReleaseRecovery(pressedAt: 10)
        XCTAssertEqual(state.sample(isHeld: false, at: 10.1), 10)
        XCTAssertNil(state.sample(isHeld: false, at: 10.2))
        XCTAssertNil(state.sample(isHeld: true, at: 11))
        XCTAssertNil(state.sample(isHeld: false, at: 12))
    }

    func testInvalidAndOutOfOrderSamplesCannotCreateLongHold() {
        var state = HotKeyReleaseRecovery(pressedAt: 10)
        XCTAssertNil(state.sample(isHeld: true, at: .nan))
        XCTAssertNil(state.sample(isHeld: true, at: .infinity))
        XCTAssertNil(state.sample(isHeld: true, at: 9))
        XCTAssertNil(state.sample(isHeld: true, at: 10.1))
        XCTAssertNil(state.sample(isHeld: true, at: 10.05))
        XCTAssertEqual(state.sample(isHeld: false, at: 12), 10.1)
    }

    func testConservativeRecoveredReleaseIntegratesWithGestureModes() {
        var short = DictationShortcutGesture()
        XCTAssertEqual(short.press(at: 10, phase: .idle), .start)
        var shortRecovery = HotKeyReleaseRecovery(pressedAt: 10)
        let shortRelease = shortRecovery.sample(isHeld: false, at: 10.1)!
        XCTAssertEqual(short.release(at: shortRelease, phase: .recording), .none)

        var held = DictationShortcutGesture()
        XCTAssertEqual(held.press(at: 20, phase: .idle), .start)
        var heldRecovery = HotKeyReleaseRecovery(pressedAt: 20)
        XCTAssertNil(heldRecovery.sample(isHeld: true, at: 21))
        let heldRelease = heldRecovery.sample(isHeld: false, at: 21.02)!
        XCTAssertEqual(held.release(at: heldRelease, phase: .preparing), .finishWhenReady)
    }
}
