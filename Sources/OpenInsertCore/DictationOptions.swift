import Foundation

public enum CleanupMode: String, CaseIterable, Codable, Sendable {
    case verbatim
    case polished
}

public struct DictationOptions: Sendable {
    public var model: String
    public var language: String
    public var vocabulary: String
    public var mode: CleanupMode

    /// Character-form conversion only; this does not translate or rewrite the transcript.
    public func applyingOrthography(to text: String) -> String {
        let hint = language.lowercased()
        if ["traditional chinese", "繁體", "zh-tw", "zh-hant"].contains(where: hint.contains) {
            return text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
        }
        return text
    }

    public init(
        model: String = "gemini-3.5-flash-lite",
        language: String = "Traditional Chinese (Taiwan), preserve spoken English",
        vocabulary: String = "",
        mode: CleanupMode = .polished
    ) {
        self.model = model
        self.language = language
        self.vocabulary = vocabulary
        self.mode = mode
    }
}
