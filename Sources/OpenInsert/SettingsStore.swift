import Foundation
import Combine
import OpenInsertCore

@MainActor final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var asrModel: String { didSet { defaults.set(asrModel, forKey: "asrModel") } }
    @Published var languageSelection: DictationLanguage { didSet { persistLanguage() } }
    @Published var customLanguage: String { didSet { persistLanguage() } }
    @Published var vocabulary: String { didSet { defaults.set(vocabulary, forKey: "vocabulary") } }
    @Published var mode: CleanupMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var hotKey: HotKeyChoice { didSet { defaults.set(hotKey.rawValue, forKey: "hotKey") } }
    @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
    @Published var cloudConsent: Bool { didSet { defaults.set(cloudConsent, forKey: "liveCloudConsent") } }

    init() {
        // Version 0.2 switches the pipeline to the models verified in Dup's provider UI.
        let oldModel = defaults.string(forKey: "model")
        model = oldModel == nil || oldModel == "gemini-3.8-flash" ? "gemini-3.5-flash-lite" : oldModel!
        asrModel = defaults.string(forKey: "asrModel") ?? "gemini-3.5-transcribe-live"
        let languagePreference = DictationLanguagePreference(
            storedSelection: defaults.string(forKey: "languageSelection"),
            storedCustomText: defaults.string(forKey: "customLanguage"),
            legacyLanguage: defaults.string(forKey: "language")
        )
        languageSelection = languagePreference.selection
        customLanguage = languagePreference.customText
        vocabulary = defaults.string(forKey: "vocabulary") ?? ""
        mode = CleanupMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .polished
        hotKey = HotKeyChoice(rawValue: defaults.string(forKey: "hotKey") ?? "") ?? .optionSpace
        restoreClipboard = defaults.object(forKey: "restoreClipboard") as? Bool ?? true
        cloudConsent = defaults.bool(forKey: "liveCloudConsent")
        persistLanguage()
    }

    var language: String {
        DictationLanguagePreference(storedSelection: languageSelection.rawValue,
                                   storedCustomText: customLanguage).hint
    }

    private func persistLanguage() {
        defaults.set(languageSelection.rawValue, forKey: "languageSelection")
        defaults.set(customLanguage, forKey: "customLanguage")
        // Retain the legacy key for older app versions and source clients.
        defaults.set(language, forKey: "language")
    }

    var options: DictationOptions {
        DictationOptions(model: model.trimmingCharacters(in: .whitespacesAndNewlines), language: language,
                         vocabulary: vocabulary, mode: mode, languagePreference: languageSelection)
    }
}
