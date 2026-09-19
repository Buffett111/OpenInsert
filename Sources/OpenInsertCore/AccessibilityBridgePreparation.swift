import Foundation

/// Tracks one activation attempt per Electron process launch, without any UI
/// references or text. Repeated focus changes must not restart its debounce.
public struct AccessibilityBridgePreparation: Sendable {
    private struct Attempt: Sendable {
        let identity: String
        let startedAt: TimeInterval?
    }
    private var attempts: [Int32: Attempt] = [:]
    public init() {}

    public func hasAttempted(processID: Int32, identity: String) -> Bool {
        attempts[processID]?.identity == identity
    }

    public mutating func recordAttempt(processID: Int32, identity: String, succeeded: Bool, at time: TimeInterval) {
        guard !hasAttempted(processID: processID, identity: identity) else { return }
        attempts[processID] = Attempt(identity: identity, startedAt: succeeded && time.isFinite ? time : nil)
    }

    public func isPreparing(processID: Int32, at time: TimeInterval) -> Bool {
        guard time.isFinite, let startedAt = attempts[processID]?.startedAt else { return false }
        let elapsed = time - startedAt
        return elapsed >= 0 && elapsed < 3
    }
}
