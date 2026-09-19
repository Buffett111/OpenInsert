import XCTest
@testable import OpenInsertCore

final class AccessibilityBridgeActivationPolicyTests: XCTestCase {
    private typealias Policy = AccessibilityBridgeActivationPolicy

    func testRenamedAppCanEnableManualFromCapabilities() {
        // No framework filename or display-name guess is required when the app
        // explicitly exposes a writable, disabled Manual capability.
        for principalClass in [nil, "NSApplication", "RenamedApplication"] as [String?] {
            XCTAssertEqual(Policy.action(principalClass: principalClass, settable: .writable,
                                         enabled: .value(false)), .enableManual)
        }
    }

    func testManualCapabilityWinsOverChromiumFallback() {
        XCTAssertEqual(Policy.action(principalClass: "BrowserCrApplication", settable: .writable,
                                     enabled: .value(false)), .enableManual)
    }

    func testEnabledManualIsNeverReenabledOrReplaced() {
        for settable in [Policy.Settable.writable, .unavailable] {
            XCTAssertEqual(Policy.action(principalClass: "BrowserCrApplication", settable: settable,
                                         enabled: .value(true)), .none)
        }
    }

    func testExactChromiumClassCanFallbackOnlyWhenManualUnavailable() {
        let unavailableCases: [(Policy.Settable, Policy.Enabled)] = [
            (.unavailable, .unavailable), (.unavailable, .value(false)), (.writable, .unavailable)
        ]
        for (settable, enabled) in unavailableCases {
            XCTAssertEqual(Policy.action(principalClass: "BrowserCrApplication", settable: settable,
                                         enabled: enabled), .enableEnhanced)
        }
    }

    func testClassNamesMustMatchExactly() {
        for principalClass in ["browsercrapplication", "BrowserCrApplication ",
                               "CustomBrowserCrApplication", "BrowserCrApplicationSubclass", "Chromium", "ChatGPT"] {
            XCTAssertEqual(Policy.action(principalClass: principalClass, settable: .unavailable,
                                         enabled: .unavailable), .none, principalClass)
        }
    }

    func testNativeAppWithoutManualCapabilityIsUnchanged() {
        for principalClass in [nil, "NSApplication", "TextEditApplication"] as [String?] {
            for enabled in [Policy.Enabled.value(false), .unavailable] {
                XCTAssertEqual(Policy.action(principalClass: principalClass, settable: .unavailable,
                                             enabled: enabled), .none)
            }
        }
    }

    func testFailedCapabilityQueryNeverFallsBack() {
        // A permission/transport failure is not evidence that Manual is absent,
        // even when the other query and the bundle metadata suggest Chromium.
        let failedCases: [(Policy.Settable, Policy.Enabled)] = [
            (.failed, .unavailable), (.failed, .value(false)), (.failed, .value(true)),
            (.writable, .failed), (.unavailable, .failed), (.failed, .failed)
        ]
        for (settable, enabled) in failedCases {
            XCTAssertEqual(Policy.action(principalClass: "BrowserCrApplication", settable: settable,
                                         enabled: enabled), .none)
        }
    }

    func testUnsupportedReadDoesNotPretendManualIsDisabled() {
        XCTAssertEqual(Policy.action(principalClass: "NSApplication", settable: .writable,
                                     enabled: .unavailable), .none)
    }
}
