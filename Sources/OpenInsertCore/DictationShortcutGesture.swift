import Foundation

/// Resolves one shortcut gesture using the keyboard events' physical timestamps.
/// Event delivery can be delayed while macOS requests permissions or the app is busy.
public struct DictationShortcutGesture: Sendable {
    public enum Phase: Sendable { case idle, preparing, recording, busy }
    public enum Action: Equatable, Sendable { case none, start, finish, finishWhenReady }

    private var pressedAt: TimeInterval?
    private static let holdThreshold: TimeInterval = 0.35

    public init() {}

    public mutating func press(at timestamp: TimeInterval, phase: Phase) -> Action {
        guard timestamp.isFinite else { reset(); return .none }
        switch phase {
        case .idle:
            pressedAt = timestamp
            return .start
        case .preparing:
            reset()
            return .finishWhenReady
        case .recording:
            reset()
            return .finish
        case .busy:
            reset()
            return .none
        }
    }

    public mutating func release(at timestamp: TimeInterval, phase: Phase) -> Action {
        let start = pressedAt
        reset()
        guard let start, timestamp.isFinite, timestamp - start >= Self.holdThreshold else { return .none }
        switch phase {
        case .preparing: return .finishWhenReady
        case .recording: return .finish
        case .idle, .busy: return .none
        }
    }

    public mutating func reset() { pressedAt = nil }
}
