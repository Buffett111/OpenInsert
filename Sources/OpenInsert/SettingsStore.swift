import Foundation
import Combine
import OpenInsertCore

@MainActor final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var vocabulary: String { didSet { defaults.set(vocabulary, forKey: "vocabulary") } }
    @Published var mode: CleanupMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var hotKey: HotKeyChoice { didSet { defaults.set(hotKey.rawValue, forKey: "hotKey") } }
    @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
    @Published var cloudConsent: Bool { didSet { defaults.set(cloudConsent, forKey: "cloudConsent") } }

    init() {
        model = defaults.string(forKey: "model") ?? "gemini-3.8-flash"
        language = defaults.string(forKey: "language") ?? "Traditional Chinese (Taiwan), preserve spoken English"
        vocabulary = defaults.string(forKey: "vocabulary") ?? ""
        mode = CleanupMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .polished
        hotKey = HotKeyChoice(rawValue: defaults.string(forKey: "hotKey") ?? "") ?? .optionSpace
        restoreClipboard = defaults.object(forKey: "restoreClipboard") as? Bool ?? true
        cloudConsent = defaults.bool(forKey: "cloudConsent")
    }

    var options: DictationOptions {
        DictationOptions(model: model.trimmingCharacters(in: .whitespacesAndNewlines), language: language,
                         vocabulary: vocabulary, mode: mode)
    }
}
