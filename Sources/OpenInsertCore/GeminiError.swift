import Foundation

/// Descriptions are fixed strings and status codes; remote bodies and keys are never exposed.
public enum GeminiError: Error, LocalizedError, Equatable {
    case invalidAPIKey, invalidModel, invalidOptions, unsupportedAudio, emptyAudio
    case requestTooLarge, responseTooLarge, invalidResponse, incompleteResponse, emptyTranscript, blocked
    case httpStatus(Int)
    case networkFailure, timeout

    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey: return "Enter a valid Gemini API key in Settings."
        case .invalidModel: return "Enter a compatible Gemini model ID, such as gemini-3.5-flash-lite for text cleanup."
        case .invalidOptions: return "Language or vocabulary settings are too long."
        case .unsupportedAudio: return "This audio format is not supported."
        case .emptyAudio: return "No audio was recorded."
        case .requestTooLarge: return "This recording is too large. Record a shorter dictation."
        case .responseTooLarge: return "The response was too large to insert safely. Record a shorter dictation."
        case .invalidResponse: return "Gemini returned an unexpected response. Nothing was inserted."
        case .incompleteResponse: return "Gemini did not finish a complete transcription. Nothing was inserted."
        case .emptyTranscript: return "No intelligible speech was returned. Nothing was inserted."
        case .blocked: return "Gemini declined this transcription. Nothing was inserted."
        case .httpStatus(let code):
            switch code {
            case 400: return "Gemini rejected the request (HTTP 400). Check the model and API key."
            case 401, 403: return "Gemini did not authorize the request (HTTP \(code)). Check the API key and project access."
            case 404: return "The Gemini model is unavailable (HTTP 404). Check the model ID."
            case 429: return "Gemini quota or rate limit reached (HTTP 429). Check your Google project quota and billing."
            case 300..<400: return "Gemini returned a redirect. It was blocked to protect your API key."
            case 500..<600: return "Gemini is temporarily unavailable (HTTP \(code)). Try again later."
            default: return "Gemini request failed (HTTP \(code)). Nothing was inserted."
            }
        case .networkFailure: return "Could not reach Gemini. Check your internet connection."
        case .timeout: return "The Gemini request timed out. Nothing was inserted."
        }
    }
}
