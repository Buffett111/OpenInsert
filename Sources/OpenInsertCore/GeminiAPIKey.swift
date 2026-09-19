import Foundation

/// Local transport-safety validation only; Google decides whether the credential is valid.
/// API keys are opaque strings, including newer authorization keys. Do not infer a fixed
/// prefix, alphabet, or provider length from older examples in Google's documentation.
public enum GeminiAPIKey {
    public static let maximumBytes = 8_192

    /// Returns the key with surrounding paste whitespace removed. Never logs its contents.
    @discardableResult
    public static func validate(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
        guard !key.isEmpty else { throw GeminiAPIKeyValidationError.missing }
        guard key.utf8.count <= maximumBytes else { throw GeminiAPIKeyValidationError.tooLong }
        guard !key.unicodeScalars.contains(where: { [9, 10, 11, 12, 13, 32].contains($0.value) }) else {
            throw GeminiAPIKeyValidationError.containsWhitespace
        }
        // Visible ASCII is safe as one HTTP header value; CR/LF, control bytes, and
        // invisible/Unicode paste artifacts must never reach URLSession's headers.
        guard key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw GeminiAPIKeyValidationError.invalidCharacters
        }
        return key
    }
}

public enum GeminiAPIKeyValidationError: Error, LocalizedError, Equatable, Sendable {
    case missing, tooLong, containsWhitespace, invalidCharacters

    public var errorDescription: String? {
        switch self {
        case .missing: return "No Gemini API key is saved. Paste the complete key from Google AI Studio in Settings."
        case .tooLong: return "The saved API key exceeds this app's 8 KiB transport limit. Paste only the API key, not a JSON file or command."
        case .containsWhitespace: return "The saved API key contains a space, tab, or line break inside it. Copy the complete key from Google AI Studio again."
        case .invalidCharacters: return "The saved API key contains an invisible, control, or non-ASCII character. Copy the complete key from Google AI Studio again."
        }
    }
}
