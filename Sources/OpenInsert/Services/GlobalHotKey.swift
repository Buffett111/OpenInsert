import Carbon
import Foundation
import ApplicationServices
import OpenInsertCore

extension KeyboardShortcut {
    fileprivate var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// Each group permits either the left or right physical modifier.
    fileprivate var modifierKeyGroups: [[CGKeyCode]] {
        var groups: [[CGKeyCode]] = []
        if modifiers.contains(.command) { groups.append([CGKeyCode(kVK_Command), CGKeyCode(kVK_RightCommand)]) }
        if modifiers.contains(.option) { groups.append([CGKeyCode(kVK_Option), CGKeyCode(kVK_RightOption)]) }
        if modifiers.contains(.control) { groups.append([CGKeyCode(kVK_Control), CGKeyCode(kVK_RightControl)]) }
        if modifiers.contains(.shift) { groups.append([CGKeyCode(kVK_Shift), CGKeyCode(kVK_RightShift)]) }
        return groups
    }

    var displayName: String {
        let prefix = (modifiers.contains(.control) ? "⌃" : "")
            + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "")
            + (modifiers.contains(.command) ? "⌘" : "")
        let names: [UInt32: String] = [36:"Return", 48:"Tab", 49:"Space", 51:"Delete", 53:"Esc",
            71:"Clear", 76:"Enter", 114:"Help", 115:"Home", 116:"Page Up", 117:"Forward Delete",
            119:"End", 121:"Page Down", 123:"←", 124:"→", 125:"↓", 126:"↑"]
        func label(_ name: String) -> String { prefix.isEmpty ? name : prefix + " " + name }
        if let name = names[keyCode] { return label(name) }
        let functionKeys: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        if let index = functionKeys.firstIndex(of: keyCode) { return label("F" + String(index + 1)) }
        guard keyCode <= 127 else { return label("Key " + String(keyCode)) }
        // Read only layout metadata to label the stored physical key.
        if let input = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let raw = TISGetInputSourceProperty(input, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
            if let bytes = CFDataGetBytePtr(data) {
                let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 8)
                var length = 0
                let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                    characters.count, &length, &characters)
                if status == noErr, length > 0 {
                    let label = String(utf16CodeUnits: characters, count: length).uppercased()
                    if label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                        return prefix.isEmpty ? label : prefix + " " + label
                    }
                }
            }
        }
        return label("Key " + String(keyCode))
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
    private var shortcut = KeyboardShortcut.optionSpace
    private let releaseMonitor = HotKeyReleaseMonitor()
    private(set) var lastReleaseSource: String?
    private var registrationID: UInt32 = 0
    private var nextRegistrationID: UInt32 = 0
    private static let signature: OSType = 0x4F494E53 // OINS

    init() {}

    func register(shortcut: KeyboardShortcut) throws {
        try shortcut.validate()
        if hotKey != nil, self.shortcut == shortcut { return }
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
        nextRegistrationID &+= 1
        let candidateID = nextRegistrationID
        let identifier = EventHotKeyID(signature: Self.signature, id: candidateID)
        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, identifier,
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &candidate)
        guard status == noErr, let candidate else {
            if let candidate { UnregisterEventHotKey(candidate) }
            throw HotKeyError(status: status == noErr ? OSStatus(paramErr) : status)
        }
        // Keep the previous registration and press recovery until success.
        if let previous = hotKey {
            let removalStatus = UnregisterEventHotKey(previous)
            guard removalStatus == noErr else {
                UnregisterEventHotKey(candidate)
                throw HotKeyError(status: removalStatus)
            }
        }
        hotKey = candidate
        registrationID = candidateID
        self.shortcut = shortcut
        pressed = false
        pressGeneration &+= 1
        releaseMonitor.stop()
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
                releaseMonitor.start(pressedAt: timestamp, keyCode: CGKeyCode(shortcut.keyCode), modifiers: shortcut.modifierKeyGroups) { [weak self] releaseTime, uncertain in
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

/// Reads the registered key and only its required modifier keys while a press
/// is outstanding. The serial queue owns its timer and state; no key data is
/// retained, logged, or sent to the provider. Carbon remains the primary path.
private final class HotKeyReleaseMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.openinsert.hotkey-release", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var generation: UInt64 = 0

    func start(pressedAt: TimeInterval, keyCode: CGKeyCode, modifiers: [[CGKeyCode]], onRelease: @escaping @Sendable (TimeInterval, Bool) -> Void) {
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
                let keyHeld = CGEventSource.keyState(.combinedSessionState, key: keyCode)
                let held = keyHeld && modifiers.allSatisfy { group in
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
