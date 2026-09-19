import Foundation

/// The app interface language is independent of speech and writing preferences.
/// Add a case and matching resource folders to offer another language package.
public enum InterfaceLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case english = "en"
    case zhHant = "zh-Hant"

    public var id: String { rawValue }

    public var nativeName: String {
        switch self {
        case .english: return "English"
        case .zhHant: return "繁體中文"
        }
    }
}
