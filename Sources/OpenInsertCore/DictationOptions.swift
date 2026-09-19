import Foundation

public enum CleanupMode: String, CaseIterable, Codable, Sendable {
    case verbatim
    case polished
}

public struct DictationOptions: Sendable {
    public var model: String
    public var language: String
    public var languagePreference: DictationLanguage?
    public var vocabulary: String
    public var mode: CleanupMode

    /// Character-form conversion only; this does not translate or rewrite the transcript.
    public func applyingOrthography(to text: String) -> String {
        switch languagePreference ?? DictationLanguage.matchingPreset(for: language) {
        case .traditionalChinese:
            return text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
        case .simplifiedChinese:
            return text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
        default:
            return text
        }
    }

    public init(
        model: String = "gemini-3.5-flash-lite",
        language: String = DictationLanguage.traditionalChinese.promptHint,
        vocabulary: String = "",
        mode: CleanupMode = .polished,
        languagePreference: DictationLanguage? = nil
    ) {
        self.model = model
        self.language = language
        self.languagePreference = languagePreference
        self.vocabulary = vocabulary
        self.mode = mode
    }
}
