import Foundation

/// Explicit per-app language selection. It never changes AppleLanguages or
/// relies on the host process's preferred language to choose a translation.
public struct AppLocalizer {
    public let language: InterfaceLanguage
    private let resourceBundle: Bundle

    public init(language: InterfaceLanguage) {
        self.init(language: language, resourceBundle: Self.resources)
    }

    // Injectable for testing missing translations against real resource bundles.
    init(language: InterfaceLanguage, resourceBundle: Bundle) {
        self.language = language
        self.resourceBundle = resourceBundle
    }

    private static let resolvedResources = resolveResources()
    static var resources: Bundle { resolvedResources }

    /// Native SwiftPM's accessor searches next to the executable and may include
    /// an absolute build path. Hand-built .app bundles keep resources in the
    /// standard Contents/Resources location instead. Never evaluate its fatal
    /// development fallback for an installed OpenInsert with missing resources.
    static func resolveResources(in mainBundle: Bundle = .main,
                                 developmentBundle: () -> Bundle = { .module }) -> Bundle {
        if let url = mainBundle.resourceURL?.appendingPathComponent("OpenInsert_OpenInsertCore.bundle"),
           let packaged = Bundle(url: url) {
            return packaged
        }
        if mainBundle.bundleURL.pathExtension == "app",
           mainBundle.bundleIdentifier == "org.openinsert.OpenInsert" {
            return mainBundle
        }
        return developmentBundle()
    }

    public func text(_ key: String, table: String = "Interface", arguments: [CVarArg] = []) -> String {
        let format = translation(key, table: table, language: language)
            ?? translation(key, table: table, language: .english)
            ?? key
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: language.rawValue), arguments: arguments)
    }

    /// SwiftPM can normalize zh-Hant.lproj to zh-hant.lproj. Bundle's named
    /// resource lookup does not consistently resolve that spelling. Match the
    /// actual locale directory by tag, preserving script/region distinctions.
    static func languageDirectory(_ language: InterfaceLanguage, in bundle: Bundle) -> URL? {
        guard let root = bundle.resourceURL,
              let entries = try? FileManager.default.contentsOfDirectory(at: root,
                  includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        func normalized(_ tag: String) -> String {
            tag.replacingOccurrences(of: "_", with: "-").lowercased()
        }
        let expected = normalized(language.rawValue)
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.first { url in
            url.pathExtension.lowercased() == "lproj"
                && normalized(url.deletingPathExtension().lastPathComponent) == expected
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func translation(_ key: String, table: String, language: InterfaceLanguage) -> String? {
        guard let directory = Self.languageDirectory(language, in: resourceBundle),
              let bundle = Bundle(url: directory) else { return nil }
        let missing = "\u{1F}OpenInsert.missing.translation\u{1F}"
        let result = bundle.localizedString(forKey: key, value: missing, table: table)
        return result == missing ? nil : result
    }
}
