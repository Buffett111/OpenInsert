import AppKit
import ApplicationServices
import Carbon
import OpenInsertCore

/// Requests one clipboard paste into the field captured when dictation began.
/// No text is read from other apps: Accessibility checks focus, role, selection
/// range and editable capabilities. Clipboard backups remain in memory.
@MainActor
final class TextInserter {
    private var activationObserver: NSObjectProtocol?
    private var electronPreparation = AccessibilityBridgePreparation()

    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.prepareCurrentApplication() }
        }
    }

    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    /// Warm up an Electron app's native Accessibility bridge after it becomes
    /// frontmost. Only framework metadata, application role and a capability
    /// flag are inspected; this never enumerates UI children or reads text.
    func prepareCurrentApplication() {
        guard AXIsProcessTrusted(), let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        prepareElectronApplication(application)
    }

    private func prepareElectronApplication(_ application: NSRunningApplication) {
        guard let bundleURL = application.bundleURL else { return }
        let framework = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework", isDirectory: true)
        // Inspect the actual application bundle; never infer Electron from its
        // display name or broadly enable an undocumented Chromium attribute.
        guard FileManager.default.fileExists(atPath: framework.path), Bundle(url: framework) != nil else { return }
        let pid = application.processIdentifier
        let identity = bundleURL.path + ":" + String(application.launchDate?.timeIntervalSince1970 ?? 0)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.75)
        var role: CFTypeRef?
        // Electron enables its native AT mode when the application role is read.
        _ = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &role)
        guard !electronPreparation.hasAttempted(processID: pid, identity: identity) else { return }
        let attribute = "AXManualAccessibility" as CFString
        var settable = DarwinBoolean(false)
        var enabled: CFTypeRef?
        guard AXUIElementIsAttributeSettable(app, attribute, &settable) == .success, settable.boolValue,
              AXUIElementCopyAttributeValue(app, attribute, &enabled) == .success,
              (enabled as? Bool) == false else { return }
        // Electron documents this flag for third-party assistive software. Its
        // current implementation debounces activation for two seconds, so send
        // it once per process launch, without sleeping on the main thread.
        // https://github.com/electron/electron/blob/main/docs/tutorial/accessibility.md
        let status = AXUIElementSetAttributeValue(app, attribute, kCFBooleanTrue)
        electronPreparation.recordAttempt(processID: pid, identity: identity, succeeded: status == .success,
                                          at: ProcessInfo.processInfo.systemUptime)
    }

    private func isElectronPreparing(_ pid: pid_t) -> Bool {
        electronPreparation.isPreparing(processID: pid, at: ProcessInfo.processInfo.systemUptime)
    }

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
        prepareElectronApplication(application)
        let element: AXUIElement
        do {
            element = try focusedElement(processID: application.processIdentifier)
            try verifyEditable(element)
        } catch let error as InsertionError {
            // Preserve permission and secure-field errors. Only a missing or
            // unsupported focus can plausibly result from an AX tree warming up.
            switch error {
            case .unsupportedInputRole, .noInputField:
                if isElectronPreparing(application.processIdentifier) { throw InsertionError.accessibilityPreparing }
            case .accessibilityReadFailed(_, let code):
                if (code == AXError.noValue.rawValue || code == AXError.attributeUnsupported.rawValue),
                   isElectronPreparing(application.processIdentifier) { throw InsertionError.accessibilityPreparing }
            default: break
            }
            throw error
        }
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
        // Some web editors acknowledge AXSelectedText writes without updating
        // their document. Use the editor's normal paste path exactly once.
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
        let status = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        guard status == .success else { throw InsertionError.accessibilityReadFailed(kAXFocusedUIElementAttribute, status.rawValue) }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw InsertionError.invalidAccessibilityValue(kAXFocusedUIElementAttribute)
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
        let role = try stringAttribute(kAXRoleAttribute, of: element)
        let subrole = try stringAttribute(kAXSubroleAttribute, of: element)
        var protectedValue: CFTypeRef?
        let protectedStatus = AXUIElementCopyAttributeValue(element, "AXProtectedContent" as CFString, &protectedValue)
        try verifyOptionalAttributeStatus(protectedStatus, attribute: "AXProtectedContent")
        if subrole == kAXSecureTextFieldSubrole || (protectedValue as? Bool) == true {
            throw InsertionError.secureField
        }
        // Restrict keyboard paste to known text controls. An arbitrary focused
        // button or web page is not evidence of an active insertion point.
        let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
        var selectedTextSettable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selectedTextSettable)
        try verifyOptionalAttributeStatus(status, attribute: kAXSelectedTextAttribute)
        guard role.map(textRoles.contains) == true || (status == .success && selectedTextSettable.boolValue) else {
            throw InsertionError.unsupportedInputRole(role)
        }
        var enabledValue: CFTypeRef?
        let enabledStatus = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledValue)
        try verifyOptionalAttributeStatus(enabledStatus, attribute: kAXEnabledAttribute)
        if enabledStatus == .success, (enabledValue as? Bool) == false {
            throw InsertionError.noInputField
        }
    }

    private func verifyOptionalAttributeStatus(_ status: AXError, attribute: String) throws {
        if status != .success && status != .attributeUnsupported && status != .noValue && status != .notImplemented {
            throw InsertionError.accessibilityReadFailed(attribute, status.rawValue)
        }
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) throws -> String? {
        var result: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
        try verifyOptionalAttributeStatus(status, attribute: attribute)
        guard status == .success else { return nil }
        guard let string = result as? String else { throw InsertionError.invalidAccessibilityValue(attribute) }
        return string
    }

    private func selectedRange(_ element: AXUIElement) throws -> Selection? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        if status == .attributeUnsupported || status == .noValue { return nil }
        guard status == .success else { throw InsertionError.accessibilityReadFailed(kAXSelectedTextRangeAttribute, status.rawValue) }
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            throw InsertionError.invalidAccessibilityValue(kAXSelectedTextRangeAttribute)
        }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else {
            throw InsertionError.invalidAccessibilityValue(kAXSelectedTextRangeAttribute)
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
        case accessibilityPreparing, unsupportedInputRole(String?)
        case accessibilityReadFailed(String, Int32), invalidAccessibilityValue(String)

        var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "目前這份 OpenInsert 尚未取得輔助使用授權。請在系統設定的輔助使用權限頁啟用 OpenInsert，再重新檢查權限。"
            case .noInputField: return "Focus an editable text field in another app before starting dictation."
            case .accessibilityPreparing:
                return "輸入欄位輔助介面準備中，請稍候約 2 秒，再點入文字欄位並重試。"
            case .unsupportedInputRole(let role):
                return "目前焦點不是可辨識的文字輸入欄位（\(String((role ?? "unknown role").prefix(64)))）。請點入可編輯的文字欄位後重試。"
            case .accessibilityReadFailed(let attribute, let code):
                let reason: String
                switch AXError(rawValue: code) {
                case .apiDisabled: reason = "輔助使用 API 已停用；請重新檢查目前這份 OpenInsert 的權限"
                case .cannotComplete: reason = "目標 App 未完成輔助使用請求，可能尚未就緒或沒有回應"
                case .attributeUnsupported: reason = "目標 App 不支援此輔助使用屬性"
                case .noValue: reason = "目標 App 尚未提供目前焦點或選取範圍"
                case .invalidUIElement: reason = "原焦點元素已失效，請重新點入輸入欄位"
                default: reason = "無法讀取輸入位置的輔助使用資料"
                }
                return "\(reason)（\(attribute)，AX \(code)）。"
            case .invalidAccessibilityValue(let attribute):
                return "目標 App 回傳的輸入位置資料格式無效（\(attribute)），請重新點入文字欄位後重試。"
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
            }
        }
    }
}
