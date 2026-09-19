import Carbon
import Foundation

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
}

/// Registers exactly one shortcut; does not install a keyboard event tap.
@MainActor
final class GlobalHotKey {
    /// Seconds since system startup when the input occurred, not when the main
    /// run loop finally dispatches it. Use these timestamps for hold duration.
    var onPress: ((TimeInterval) -> Void)?
    var onRelease: ((TimeInterval) -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var pressed = false
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
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        pressed = false
    }

    private func receive(eventKind: UInt32, registrationID: UInt32, timestamp: TimeInterval) {
        guard hotKey != nil, registrationID == self.registrationID else { return }
        if eventKind == UInt32(kEventHotKeyPressed), !pressed {
            pressed = true
            onPress?(timestamp)
        } else if eventKind == UInt32(kEventHotKeyReleased), pressed {
            pressed = false
            onRelease?(timestamp)
        }
    }

    deinit {
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
