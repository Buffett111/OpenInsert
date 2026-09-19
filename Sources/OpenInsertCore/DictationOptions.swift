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

    public init(
        model: String = "gemini-3.8-flash",
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
