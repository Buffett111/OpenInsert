import Foundation
import ApplicationServices
import OpenInsertCore

/// Retains app-owned message structure, so switching interface language never
/// translates or replaces recognized speech, vocabulary, or destination text.
struct LocalizedMessage {
    private let renderer: (AppLocalizer) -> String

    init(_ key: String, _ arguments: [CVarArg] = []) {
        renderer = { $0.text(key, table: "Status", arguments: arguments) }
    }

    init(_ key: String, values: [LocalizedMessage]) {
        renderer = { localizer in
            localizer.text(key, table: "Status", arguments: values.map { $0.render(using: localizer) })
        }
    }

    private init(renderer: @escaping (AppLocalizer) -> String) { self.renderer = renderer }
    static func literal(_ value: String) -> Self { Self(renderer: { _ in value }) }
    static func joined(_ messages: [Self], separator: String = "") -> Self {
        Self(renderer: { localizer in
            messages.map { $0.render(using: localizer) }.filter { !$0.isEmpty }.joined(separator: separator)
        })
    }
    func render(using localizer: AppLocalizer) -> String { renderer(localizer) }

    static func error(_ error: Error) -> Self {
        if error is CancellationError { return Self("error.cancelled") }
        if let error = error as? KeyboardShortcut.ValidationError {
            return Self(renderer: { $0.text(error.localizationKey, table: "Shortcuts") })
        }
        if let error = error as? GlobalHotKey.HotKeyError { return Self("shortcut.failed", [error.status]) }
        if let error = error as? GeminiAPIKeyValidationError {
            switch error {
            case .missing: return Self("error.key.missing")
            case .tooLong: return Self("error.key.tooLong")
            case .containsWhitespace: return Self("error.key.whitespace")
            case .invalidCharacters: return Self("error.key.characters")
            }
        }
        if let error = error as? GeminiLiveError {
            switch error {
            case .invalidConfiguration: return Self("error.live.configuration")
            case .invalidAPIKey(let issue): return Self.error(issue)
            case .invalidModel: return Self("error.live.model")
            case .invalidLanguageCodes: return Self("error.live.languages")
            case .invalidVocabulary: return Self("error.live.vocabulary")
            case .invalidState: return Self("error.live.state")
            case .invalidAudio: return Self("error.live.audio")
            case .audioTooLong: return Self("error.live.tooLong")
            case .setupTimeout: return Self("error.live.setupTimeout")
            case .finalizationTimeout: return Self("error.live.finishTimeout")
            case .network: return Self("error.live.network")
            case .serverRejected: return Self("error.live.rejected")
            case .invalidResponse: return Self("error.live.response")
            case .oversizedResponse: return Self("error.live.oversized")
            case .emptyTranscript: return Self("error.gemini.emptyTranscript")
            case .interrupted: return Self("error.live.interrupted")
            }
        }
        if let error = error as? GeminiError {
            switch error {
            case .invalidAPIKey: return Self("error.gemini.key")
            case .invalidModel: return Self("error.gemini.model")
            case .invalidOptions: return Self("error.gemini.options")
            case .unsupportedAudio: return Self("error.gemini.audio")
            case .emptyAudio: return Self("error.gemini.emptyAudio")
            case .requestTooLarge: return Self("error.gemini.requestLarge")
            case .responseTooLarge: return Self("error.gemini.responseLarge")
            case .invalidResponse: return Self("error.gemini.response")
            case .incompleteResponse: return Self("error.gemini.incomplete")
            case .emptyTranscript: return Self("error.gemini.emptyTranscript")
            case .blocked: return Self("error.gemini.blocked")
            case .networkFailure: return Self("error.gemini.network")
            case .timeout: return Self("error.gemini.timeout")
            case .cleanupTimeout: return Self("error.gemini.cleanupTimeout")
            case .httpStatus(let code):
                switch code {
                case 400: return Self("error.http.badRequest")
                case 401, 403: return Self("error.http.unauthorized", [code])
                case 404: return Self("error.http.model")
                case 429: return Self("error.http.quota")
                case 300..<400: return Self("error.http.redirect")
                case 500..<600: return Self("error.http.unavailable", [code])
                default: return Self("error.http.other", [code])
                }
            }
        }
        if let error = error as? StreamingRecorderError {
            switch error {
            case .alreadyRecording: return Self("error.audio.recording")
            case .microphoneDenied: return Self("error.audio.permission")
            case .noInputDevice: return Self("error.audio.device")
            case .conversionFailed: return Self("error.audio.conversion")
            case .inputDeviceChanged: return Self("error.audio.changed")
            case .captureOverflow: return Self("error.audio.overflow")
            case .networkBackpressure: return Self("error.audio.backpressure")
            }
        }
        if let error = error as? TextInserter.InsertionError {
            switch error {
            case .accessibilityDenied: return Self("error.insert.permission")
            case .noInputField: return Self("error.insert.noField")
            case .secureField: return Self("error.insert.secure")
            case .targetChanged: return Self("error.insert.targetChanged")
            case .selectionChanged: return Self("error.insert.selectionChanged")
            case .emptyText: return Self("error.insert.empty")
            case .modifierHeld: return Self("error.insert.modifier")
            case .eventCreationFailed: return Self("error.insert.event")
            case .clipboardChanged: return Self("error.insert.clipboardChanged")
            case .clipboardUnreadable: return Self("error.insert.clipboardUnreadable")
            case .clipboardWriteFailed: return Self("error.insert.clipboardWrite")
            case .terminalControlText: return Self("error.insert.terminal")
            case .accessibilityPreparing: return Self("error.insert.preparing")
            case .unsupportedInputRole(let role): return Self("error.insert.role", [String((role ?? "unknown").prefix(64))])
            case .invalidAccessibilityValue(let attribute): return Self("error.insert.value", [attribute])
            case .accessibilityReadFailed(let attribute, let code):
                let reason: String
                switch AXError(rawValue: code) {
                case .apiDisabled: reason = "error.ax.disabled"
                case .cannotComplete: reason = "error.ax.incomplete"
                case .attributeUnsupported: reason = "error.ax.unsupported"
                case .noValue: reason = "error.ax.noValue"
                case .invalidUIElement: reason = "error.ax.invalidElement"
                default: reason = "error.ax.read"
                }
                return Self("error.ax.details", values: [Self(reason), .literal(attribute), .literal(String(code))])
            }
        }
        if let error = error as? KeychainStore.KeychainError { return Self("error.keychain", [error.status]) }
        if error is DiagnosticSpeechError { return Self("error.synthetic") }
        // Unknown OS failures expose only their error code, not arbitrary
        // descriptions that may include provider payloads or credentials.
        return Self("error.unknown", [(error as NSError).code])
    }
}
