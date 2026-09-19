import Foundation

/// Writing preferences, not translation targets or a restriction on spoken languages.
public enum DictationLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case traditionalChinese
    case automatic
    case simplifiedChinese
    case english
    case japanese
    case korean
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .traditionalChinese: return "繁體中文（台灣）"
        case .automatic: return "自動（保留原字形）"
        case .simplifiedChinese: return "簡體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어（韓語）"
        case .custom: return "自訂…"
        }
    }

    public var promptHint: String {
        let preserve = "Preserve all languages actually spoken, including mixed Chinese and English. Do not translate."
        switch self {
        case .traditionalChinese: return "Traditional Chinese (Taiwan) character forms and punctuation. " + preserve
        case .automatic: return "Automatic writing preference: preserve the transcript's original character forms. " + preserve
        case .simplifiedChinese: return "Simplified Chinese character forms and punctuation. " + preserve
        case .english: return "English spelling and punctuation where English is spoken. " + preserve
        case .japanese: return "Japanese spelling and punctuation where Japanese is spoken. " + preserve
        case .korean: return "Korean spelling and punctuation where Korean is spoken. " + preserve
        case .custom: return ""
        }
    }

    /// Recognize exact presets and legacy labels without discarding an arbitrary
    /// custom sentence merely because it mentions a language somewhere inside it.
    public static func matchingPreset(for hint: String) -> Self? {
        let key = hint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = allCases.first(where: { $0 != .custom && $0.promptHint.lowercased() == key }) {
            return exact
        }
        switch key {
        case "traditional chinese (taiwan), preserve spoken english", "traditional chinese",
             "traditional chinese (taiwan)", "繁體中文", "繁體中文（台灣）", "中文（繁體）",
             "繁體", "zh-tw", "zh-hant", "zh-hant-tw": return .traditionalChinese
        case "", "auto", "automatic", "自動", "自動偵測", "自动": return .automatic
        case "simplified chinese", "简体中文", "簡體中文", "简体", "zh-cn", "zh-hans": return .simplifiedChinese
        case "english", "英文", "英語", "en": return .english
        case "japanese", "日本語", "日文", "ja": return .japanese
        case "korean", "한국어", "韓語", "韓文", "ko": return .korean
        default: return nil
        }
    }
}

/// Pure migration logic, independent of UserDefaults and any credentials.
public struct DictationLanguagePreference: Equatable, Sendable {
    public var selection: DictationLanguage
    public var customText: String

    public init(storedSelection: String? = nil, storedCustomText: String? = nil, legacyLanguage: String? = nil) {
        if let storedSelection, let selection = DictationLanguage(rawValue: storedSelection) {
            self.selection = selection
            self.customText = storedCustomText ?? (selection == .custom ? legacyLanguage ?? "" : "")
        } else if let legacyLanguage {
            self.selection = DictationLanguage.matchingPreset(for: legacyLanguage) ?? .custom
            self.customText = selection == .custom ? legacyLanguage : storedCustomText ?? ""
        } else {
            self.selection = .traditionalChinese
            self.customText = storedCustomText ?? ""
        }
    }

    public var hint: String {
        guard selection == .custom else { return selection.promptHint }
        return customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? DictationLanguage.automatic.promptHint : customText
    }
}
