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

    /// Local writing-system formatting for previews and accepted final text.
    /// Chinese preferences also remove single ASR segmentation spaces; this
    /// never translates words or makes an additional provider request.
    public func applyingOrthography(to text: String) -> String {
        switch languagePreference ?? DictationLanguage.matchingPreset(for: language) {
        case .traditionalChinese:
            let converted = text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
            return ChineseSpacingNormalizer.normalize(converted)
        case .simplifiedChinese:
            let converted = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
            return ChineseSpacingNormalizer.normalize(converted)
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
