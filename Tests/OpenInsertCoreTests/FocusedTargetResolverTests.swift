import XCTest
@testable import OpenInsertCore

final class FocusedTargetResolverTests: XCTestCase {
    private enum TestError: Error, Equatable { case noValue, unsupported, permissionDenied, unresponsive, invalidElement }

    func testSystemWideFocusWinsWithoutQueryingApplication() throws {
        var sources: [FocusedTargetResolver.Source] = []
        let result = try FocusedTargetResolver.resolve(expectedProcessID: 10, currentForegroundProcessID: { 10 }) { source in
            sources.append(source)
            return .found("editor", processID: 10)
        }
        XCTAssertEqual(result, "editor")
        XCTAssertEqual(sources, [.systemWide])
    }

    func testNoValueCanRecoverThroughSameForegroundApplication() throws {
        var sources: [FocusedTargetResolver.Source] = []
        let result: String = try FocusedTargetResolver.resolve(expectedProcessID: 10, currentForegroundProcessID: { 10 }) { source in
            sources.append(source)
            return source == .systemWide ? .unavailable(TestError.noValue) : .found("editor", processID: 10)
        }
        XCTAssertEqual(result, "editor")
        XCTAssertEqual(sources, [.systemWide, .application])
    }

    func testBothUnavailableStopAfterTwoQueriesAndPreserveFinalError() {
        var sources: [FocusedTargetResolver.Source] = []
        XCTAssertThrowsError(try FocusedTargetResolver.resolve(expectedProcessID: 10, currentForegroundProcessID: { 10 }) { source -> FocusedTargetResolver.Lookup<String> in
            sources.append(source)
            return .unavailable(source == .systemWide ? TestError.unsupported : TestError.noValue)
        }) { XCTAssertEqual($0 as? TestError, .noValue) }
        XCTAssertEqual(sources, [.systemWide, .application])
    }

    func testForeignSystemFocusIsRejectedWithoutApplicationFallback() {
        var sources: [FocusedTargetResolver.Source] = []
        XCTAssertThrowsError(try FocusedTargetResolver.resolve(expectedProcessID: 10, currentForegroundProcessID: { 10 }) { source in
            sources.append(source)
            return .found("another app", processID: 20)
        }) { XCTAssertEqual($0 as? FocusedTargetResolver.Failure, .foreignProcess) }
        XCTAssertEqual(sources, [.systemWide])
    }

    func testForeignApplicationFallbackIsRejected() {
        XCTAssertThrowsError(try FocusedTargetResolver.resolve(expectedProcessID: 10, currentForegroundProcessID: { 10 }) { source -> FocusedTargetResolver.Lookup<String> in
            source == .systemWide ? .unavailable(TestError.noValue) : .found("another app", processID: 20)
        }) { XCTAssertEqual($0 as? FocusedTargetResolver.Failure, .foreignProcess) }
    }

    func testInitialForegroundMismatchMakesNoAXQuery() {
        var calls = 0
        XCTAssertThrowsError(try FocusedTargetResolver.resolve(expectedProcessID: 10, currentForegroundProcessID: { 20 }) { _ in
            calls += 1
            return .found("editor", processID: 10)
        }) { XCTAssertEqual($0 as? FocusedTargetResolver.Failure, .foregroundChanged) }
        XCTAssertEqual(calls, 0)
    }

    func testForegroundChangeDuringSystemQueryRejectsItsResult() {
        var foreground: Int32? = 10
        XCTAssertThrowsError(try FocusedTargetResolver.resolve(expectedProcessID: 10, currentForegroundProcessID: { foreground }) { _ in
            foreground = 20
            return .found("old editor", processID: 10)
        }) { XCTAssertEqual($0 as? FocusedTargetResolver.Failure, .foregroundChanged) }
    }

    func testForegroundChangeDuringFallbackRejectsItsResult() {
        var foreground: Int32? = 10
        XCTAssertThrowsError(try FocusedTargetResolver.resolve(expectedProcessID: 10, currentForegroundProcessID: { foreground }) { source -> FocusedTargetResolver.Lookup<String> in
            if source == .systemWide { return .unavailable(TestError.noValue) }
            foreground = nil
            return .found("old editor", processID: 10)
        }) { XCTAssertEqual($0 as? FocusedTargetResolver.Failure, .foregroundChanged) }
    }

    func testPermissionUnresponsiveAndInvalidFailuresNeverTriggerFallback() {
        for failure in [TestError.permissionDenied, .unresponsive, .invalidElement] {
            var calls = 0
            XCTAssertThrowsError(try FocusedTargetResolver.resolve(expectedProcessID: 10, currentForegroundProcessID: { 10 }) { _ -> FocusedTargetResolver.Lookup<String> in
                calls += 1
                throw failure
            }) { XCTAssertEqual($0 as? TestError, failure) }
            XCTAssertEqual(calls, 1)
        }
    }
}
