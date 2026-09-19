import Carbon
import Foundation
import ApplicationServices
import OpenInsertCore

enum HotKeyChoice: String, CaseIterable, Identifiable {
    case controlOptionSpace
    case optionSpace
    case controlShiftSpace

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .controlOptionSpace: return "⌃⌥ Space"
        case .optionSpace: return "⌥ Space"
        case .controlShiftSpace: return "⌃⇧ Space"
        }
    }

    fileprivate var carbonModifiers: UInt32 {
        switch self {
        case .controlOptionSpace: return UInt32(controlKey | optionKey)
        case .optionSpace: return UInt32(optionKey)
        case .controlShiftSpace: return UInt32(controlKey | shiftKey)
        }
    }

    /// Each group permits either the left or right physical modifier.
    fileprivate var modifierKeyGroups: [[CGKeyCode]] {
        switch self {
        case .controlOptionSpace: return [[CGKeyCode(kVK_Control), CGKeyCode(kVK_RightControl)], [CGKeyCode(kVK_Option), CGKeyCode(kVK_RightOption)]]
        case .optionSpace: return [[CGKeyCode(kVK_Option), CGKeyCode(kVK_RightOption)]]
        case .controlShiftSpace: return [[CGKeyCode(kVK_Control), CGKeyCode(kVK_RightControl)], [CGKeyCode(kVK_Shift), CGKeyCode(kVK_RightShift)]]
        }
    }
}

/// Registers exactly one shortcut; does not install a keyboard event tap.
@MainActor
final class GlobalHotKey {
    /// Seconds since system startup when the input occurred, not when the main
    /// run loop finally dispatches it. Use these timestamps for hold duration.
    var onPress: ((TimeInterval) -> Void)?
    var onRelease: ((TimeInterval) -> Void)?
    /// The press reached this process too late to distinguish a tap from a
    /// completed hold. Cancel any active recording rather than keeping it open.
    var onUncertainRelease: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var pressed = false
    private var pressedAt: TimeInterval = 0
    private var pressGeneration: UInt64 = 0
    private var choice = HotKeyChoice.optionSpace
    private let releaseMonitor = HotKeyReleaseMonitor()
    private(set) var lastReleaseSource: String?
    private var registrationID: UInt32 = 0
    private static let signature: OSType = 0x4F494E53 // OINS

    init() {}

    func register(choice: HotKeyChoice) throws {
        unregister()
        if handler == nil {
            var events = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
            ]
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size,
                    nil, &identifier)
                guard status == noErr, identifier.signature == 0x4F494E53 else {
                    return OSStatus(eventNotHandledErr)
                }
                let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                let eventKind = GetEventKind(event)
                let eventID = identifier.id
                let eventTime = GetEventTime(event)
                // Carbon application events are dispatched by the main run loop.
                MainActor.assumeIsolated {
                    owner.receive(eventKind: eventKind, registrationID: eventID, timestamp: eventTime)
                }
                return noErr
            }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { throw HotKeyError(status: status) }
        }
        registrationID &+= 1
        let identifier = EventHotKeyID(signature: Self.signature, id: registrationID)
        let status = RegisterEventHotKey(UInt32(kVK_Space), choice.carbonModifiers, identifier,
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        guard status == noErr else { throw HotKeyError(status: status) }
        self.choice = choice
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        pressed = false
        pressGeneration &+= 1
        releaseMonitor.stop()
    }

    private func receive(eventKind: UInt32, registrationID: UInt32, timestamp: TimeInterval) {
        guard hotKey != nil, registrationID == self.registrationID else { return }
        if eventKind == UInt32(kEventHotKeyPressed), !pressed {
            pressed = true
            pressedAt = timestamp
            pressGeneration &+= 1
            let pressID = pressGeneration
            // Start outside the main queue before onPress can synchronously
            // request Keychain/AX/audio startup. Only an existing AX grant is used;
            // this never installs a keyboard tap or requests Input Monitoring.
            if AXIsProcessTrusted() {
                releaseMonitor.start(pressedAt: timestamp, modifiers: choice.modifierKeyGroups) { [weak self] releaseTime, uncertain in
                    // Allow already queued Carbon events to supply the exact
                    // physical timestamp before using a conservative snapshot.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.075) { [weak self] in
                        guard let self, self.hotKey != nil, self.registrationID == registrationID,
                              self.pressGeneration == pressID else { return }
                        self.completeRelease(at: releaseTime, source: uncertain ? "uncertain key-state recovery" : "key-state recovery", uncertain: uncertain)
                    }
                }
            }
            onPress?(timestamp)
        } else if eventKind == UInt32(kEventHotKeyReleased), timestamp >= pressedAt {
            // An old Carbon Released can arrive after recovery and a new press.
            completeRelease(at: timestamp, source: "Carbon")
        }
    }

    private func completeRelease(at timestamp: TimeInterval, source: String, uncertain: Bool = false) {
        guard pressed else { return }
        pressed = false
        pressGeneration &+= 1
        releaseMonitor.stop()
        lastReleaseSource = source
        if uncertain { onUncertainRelease?() }
        else { onRelease?(timestamp) }
    }

    deinit {
        releaseMonitor.stop()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    struct HotKeyError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "Could not register the global shortcut (\(status)). It may be in use by another app; choose a different shortcut."
        }
    }
}

/// Reads Space and only the registered shortcut's modifier keys while a press
/// is outstanding. The serial queue owns its timer and state; no key data is
/// retained, logged, or sent to the provider. Carbon remains the primary path.
private final class HotKeyReleaseMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.openinsert.hotkey-release", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var generation: UInt64 = 0

    func start(pressedAt: TimeInterval, modifiers: [[CGKeyCode]], onRelease: @escaping @Sendable (TimeInterval, Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.generation &+= 1
            let generation = self.generation
            var recovery = HotKeyReleaseRecovery(pressedAt: pressedAt)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            self.timer = timer
            timer.schedule(deadline: .now(), repeating: .milliseconds(15), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                guard let self, self.generation == generation else { return }
                let spaceHeld = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Space))
                let held = spaceHeld && modifiers.allSatisfy { group in
                    group.contains { CGEventSource.keyState(.combinedSessionState, key: $0) }
                }
                // GetCurrentEventTime shares Carbon's seconds-since-boot clock.
                if let timestamp = recovery.sample(isHeld: held, at: GetCurrentEventTime()) {
                    self.timer?.cancel()
                    self.timer = nil
                    onRelease(timestamp, recovery.releaseIsUncertain)
                }
            }
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.generation &+= 1
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    deinit { timer?.cancel() }
}
