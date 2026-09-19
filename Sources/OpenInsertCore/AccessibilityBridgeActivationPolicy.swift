/// Chooses only a supported manual activation or the narrowly identified
/// Chromium application path. Transport and permission errors are not evidence
/// that an attribute is unavailable.
public enum AccessibilityBridgeActivationPolicy {
    public enum Settable: Equatable, Sendable {
        case writable, unavailable, failed
    }
    public enum Enabled: Equatable, Sendable {
        case value(Bool), unavailable, failed
    }
    public enum Action: Equatable, Sendable {
        case none, enableManual, enableEnhanced
    }

    public static func action(principalClass: String?, settable: Settable, enabled: Enabled) -> Action {
        guard settable != .failed, enabled != .failed else { return .none }
        if enabled == .value(true) { return .none }
        if settable == .writable, enabled == .value(false) { return .enableManual }
        // Chromium's BrowserCrApplication has an AXEnhancedUserInterface setter
        // but no matching getter. Do not infer this from an app's display name.
        if principalClass == "BrowserCrApplication",
           settable == .unavailable || enabled == .unavailable {
            return .enableEnhanced
        }
        return .none
    }
}
