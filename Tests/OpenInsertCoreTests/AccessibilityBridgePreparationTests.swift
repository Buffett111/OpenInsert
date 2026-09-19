import XCTest
@testable import OpenInsertCore

final class AccessibilityBridgePreparationTests: XCTestCase {
    func testRepeatedFocusDoesNotRestartElectronDebounce() {
        var state = AccessibilityBridgePreparation()
        state.recordAttempt(processID: 42, identity: "app:launch1", succeeded: true, at: 10)
        XCTAssertTrue(state.hasAttempted(processID: 42, identity: "app:launch1"))
        state.recordAttempt(processID: 42, identity: "app:launch1", succeeded: true, at: 12)
        XCTAssertTrue(state.isPreparing(processID: 42, at: 12.9))
        XCTAssertFalse(state.isPreparing(processID: 42, at: 13))
    }

    func testPIDReuseByANewAppLaunchAllowsANewAttempt() {
        var state = AccessibilityBridgePreparation()
        state.recordAttempt(processID: 42, identity: "app:launch1", succeeded: true, at: 10)
        XCTAssertFalse(state.hasAttempted(processID: 42, identity: "app:launch2"))
        state.recordAttempt(processID: 42, identity: "app:launch2", succeeded: true, at: 30)
        XCTAssertTrue(state.isPreparing(processID: 42, at: 31))
    }

    func testFailedActivationDoesNotHideOriginalAXFailureBehindPreparing() {
        var state = AccessibilityBridgePreparation()
        state.recordAttempt(processID: 42, identity: "app:launch1", succeeded: false, at: 10)
        XCTAssertTrue(state.hasAttempted(processID: 42, identity: "app:launch1"))
        XCTAssertFalse(state.isPreparing(processID: 42, at: 10.1))
    }

    func testUnknownAppAndInvalidTimesNeverReportPreparing() {
        var state = AccessibilityBridgePreparation()
        XCTAssertFalse(state.isPreparing(processID: 42, at: 10))
        state.recordAttempt(processID: 42, identity: "app:launch1", succeeded: true, at: 10)
        XCTAssertFalse(state.isPreparing(processID: 43, at: 11))
        XCTAssertFalse(state.isPreparing(processID: 42, at: 9))
        XCTAssertFalse(state.isPreparing(processID: 42, at: .nan))
        XCTAssertFalse(state.isPreparing(processID: 42, at: .infinity))
    }
}
