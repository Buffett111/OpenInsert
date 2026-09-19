import Foundation

/// A conservative fallback for a registered hotkey's missing release event.
/// Samples contain only whether that exact combination is still held.
public struct HotKeyReleaseRecovery: Sendable {
    private let pressedAt: TimeInterval
    private var lastHeldAt: TimeInterval?
    private var lastSampleAt: TimeInterval?
    private var completed = false
    public private(set) var releaseIsUncertain = false

    public init(pressedAt: TimeInterval) { self.pressedAt = pressedAt }

    /// Return a release timestamp once, using the last confirmed held sample.
    /// The polling/delivery delay must never turn a short tap into a long hold.
    /// If already released at the first sample, the timestamp stays conservative.
    /// Callers must cancel instead of interpreting it as a tap when
    /// releaseIsUncertain is true: snapshots cannot recover a missed duration.
    public mutating func sample(isHeld: Bool, at timestamp: TimeInterval) -> TimeInterval? {
        guard !completed, pressedAt.isFinite, timestamp.isFinite,
              timestamp >= pressedAt, timestamp >= (lastSampleAt ?? pressedAt) else { return nil }
        lastSampleAt = timestamp
        if isHeld {
            lastHeldAt = timestamp
            return nil
        }
        completed = true
        releaseIsUncertain = lastHeldAt == nil && timestamp - pressedAt >= 0.35
        return lastHeldAt ?? pressedAt
    }
}
