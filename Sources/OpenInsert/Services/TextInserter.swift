import AppKit
import ApplicationServices
import Carbon

/// Inserts only into the field captured when dictation began. No text is read
/// from other apps: Accessibility is used only for focus, role, selection range,
/// and an optional selected-text write. Clipboard data never leaves this class.
@MainActor
final class TextInserter {
    struct Target {
        fileprivate let processID: pid_t
        fileprivate let element: AXUIElement
        fileprivate let selection: Selection?
        let applicationName: String
        let bundleIdentifier: String?
    }

    fileprivate struct Selection: Equatable {
        let location: CFIndex
        let length: CFIndex
    }

    func captureTarget() throws -> Target {
        guard AXIsProcessTrusted() else { throw InsertionError.accessibilityDenied }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw InsertionError.noInputField
        }
        let element = try focusedElement(processID: application.processIdentifier)
        try verifyEditable(element)
        return Target(processID: application.processIdentifier, element: element,
                      selection: try selectedRange(element),
                      applicationName: application.localizedName ?? "the original app",
                      bundleIdentifier: application.bundleIdentifier)
    }

    func insert(_ text: String, into target: Target, restoreClipboard: Bool) async throws -> String {
        guard !text.isEmpty else { throw InsertionError.emptyText }
        // Terminals can execute pasted newlines even without a Return key event.
        // Integrated terminals in other apps cannot reliably be identified by
        // these metadata, so the UI must not promise that paste never submits.
        if isTerminal(target), text.unicodeScalars.contains(where: {
            $0.value == 9 || CharacterSet.newlines.contains($0)
        }) {
            throw InsertionError.terminalControlText
        }
        try validate(target)
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(target.element, kAXSelectedTextAttribute as CFString, &settable)
        if status == .success, settable.boolValue {
            // Do not fall back after a failed write: an app may have consumed it
            // even when the Accessibility request times out.
            let result = AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, text as CFString)
            guard result == .success else { throw InsertionError.accessibilityWriteFailed(result.rawValue) }
            return "Inserted into \(target.applicationName) using Accessibility."
        }

        let pasteboard = NSPasteboard.general
        let previous = restoreClipboard ? try ClipboardSnapshot(pasteboard) : nil
        try validate(target)
        let heldModifiers = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        guard heldModifiers.isEmpty else { throw InsertionError.modifierHeld }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            throw InsertionError.eventCreationFailed
        }
        if let previous, pasteboard.changeCount != previous.changeCount {
            throw InsertionError.clipboardChanged
        }
        let clearedChangeCount = pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        guard pasteboard.writeObjects([item]) else {
            if pasteboard.changeCount == clearedChangeCount { previous?.restore(to: pasteboard) }
            throw InsertionError.clipboardWriteFailed
        }
        let ownedChangeCount = pasteboard.changeCount
        do { try validate(target) }
        catch {
            if pasteboard.changeCount == ownedChangeCount { previous?.restore(to: pasteboard) }
            throw error
        }
        guard pasteboard.changeCount == ownedChangeCount else { throw InsertionError.clipboardChanged }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        // Paste dispatch has no receipt. Give the receiving app time to request
        // the clipboard, and preserve anything the user copies in the meantime.
        // Cancellation must not shorten this interval and restore the clipboard
        // before the destination has had an opportunity to read it.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(800)) {
                continuation.resume()
            }
        }
        if pasteboard.changeCount == ownedChangeCount { previous?.restore(to: pasteboard) }
        return "Paste requested in \(target.applicationName). Check the destination; some apps block simulated paste."
    }

    private func isTerminal(_ target: Target) -> Bool {
        let identifiers: Set<String> = [
            "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "dev.warp.warp",
            "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty"
        ]
        if let identifier = target.bundleIdentifier?.lowercased(), identifiers.contains(identifier) { return true }
        let name = target.applicationName.lowercased()
        return ["terminal", "iterm", "warp", "ghostty", "kitty", "alacritty"].contains(where: name.contains)
    }

    private func validate(_ target: Target) throws {
        guard AXIsProcessTrusted() else { throw InsertionError.accessibilityDenied }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID else {
            throw InsertionError.targetChanged
        }
        let current = try focusedElement(processID: target.processID)
        guard CFEqual(current, target.element) else { throw InsertionError.targetChanged }
        try verifyEditable(current)
        guard try selectedRange(current) == target.selection else { throw InsertionError.selectionChanged }
    }

    private func focusedElement(processID: pid_t) throws -> AXUIElement {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.75)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw InsertionError.noInputField
        }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.75)
        var actualPID: pid_t = 0
        guard AXUIElementGetPid(element, &actualPID) == .success, actualPID == processID else {
            throw InsertionError.targetChanged
        }
        return element
    }

    private func verifyEditable(_ element: AXUIElement) throws {
        // A terminal password prompt may still expose an ordinary AXTextArea.
        // Honor macOS Secure Event Input as well as the field's AX metadata.
        guard !IsSecureEventInputEnabled() else { throw InsertionError.secureField }
        let role = stringAttribute(kAXRoleAttribute, of: element)
        let subrole = stringAttribute(kAXSubroleAttribute, of: element)
        var protectedValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, "AXProtectedContent" as CFString, &protectedValue)
        if subrole == kAXSecureTextFieldSubrole || (protectedValue as? Bool) == true {
            throw InsertionError.secureField
        }
        // Restrict keyboard paste to known text controls. An arbitrary focused
        // button or web page is not evidence of an active insertion point.
        let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
        var selectedTextSettable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selectedTextSettable)
        guard role.map(textRoles.contains) == true || (status == .success && selectedTextSettable.boolValue) else {
            throw InsertionError.noInputField
        }
        var enabledValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledValue) == .success,
           (enabledValue as? Bool) == false {
            throw InsertionError.noInputField
        }
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result as? String
    }

    private func selectedRange(_ element: AXUIElement) throws -> Selection? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        if status == .attributeUnsupported || status == .noValue { return nil }
        guard status == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            throw InsertionError.targetChanged
        }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else {
            throw InsertionError.targetChanged
        }
        return Selection(location: range.location, length: range.length)
    }

    private struct ClipboardSnapshot {
        let changeCount: Int
        let items: [[(NSPasteboard.PasteboardType, Data)]]

        init(_ pasteboard: NSPasteboard) throws {
            changeCount = pasteboard.changeCount
            items = try (pasteboard.pasteboardItems ?? []).map { item in
                try item.types.map { type in
                    guard let data = item.data(forType: type) else { throw InsertionError.clipboardUnreadable }
                    return (type, data)
                }
            }
            guard changeCount == pasteboard.changeCount else { throw InsertionError.clipboardChanged }
        }

        @discardableResult
        func restore(to pasteboard: NSPasteboard) -> Bool {
            let restored = items.map { types in
                let item = NSPasteboardItem()
                for (type, data) in types { item.setData(data, forType: type) }
                return item
            }
            pasteboard.clearContents()
            return restored.isEmpty || pasteboard.writeObjects(restored)
        }
    }

    enum InsertionError: LocalizedError {
        case accessibilityDenied, noInputField, secureField, targetChanged, selectionChanged
        case emptyText, modifierHeld, eventCreationFailed, clipboardChanged, clipboardUnreadable, clipboardWriteFailed
        case terminalControlText
        case accessibilityWriteFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "Enable OpenInsert in System Settings → Privacy & Security → Accessibility, then try again."
            case .noInputField: return "Focus an editable text field in another app before starting dictation."
            case .secureField: return "OpenInsert does not insert into password or protected fields."
            case .targetChanged: return "The original input field is no longer focused. Your result is preserved for copying."
            case .selectionChanged: return "The cursor or selection changed during dictation. Your result is preserved for copying."
            case .emptyText: return "There is no text to insert."
            case .terminalControlText:
                return "Automatic insertion of newlines or tabs into terminal apps is disabled because paste can execute commands. Review the result and copy it manually."
            case .modifierHeld: return "Release modifier keys before inserting. Your result is preserved for copying."
            case .eventCreationFailed: return "macOS could not create the paste event. Your result is preserved for copying."
            case .clipboardChanged: return "The clipboard changed while preparing insertion. Your result is preserved for copying."
            case .clipboardUnreadable: return "Some clipboard content cannot be backed up. Copy your result manually to preserve it."
            case .clipboardWriteFailed: return "macOS could not prepare the clipboard for pasting."
            case .accessibilityWriteFailed(let code):
                return "The destination did not confirm text insertion (Accessibility \(code)). Check it before retrying to avoid duplicate text."
            }
        }
    }
}
