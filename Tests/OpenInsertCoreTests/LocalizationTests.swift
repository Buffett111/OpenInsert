import Foundation
import XCTest
@testable import OpenInsertCore

final class LocalizationTests: XCTestCase {
    func testLanguageIdentifiersAndNativeNamesRoundTrip() throws {
        XCTAssertEqual(InterfaceLanguage.english.rawValue, "en")
        XCTAssertEqual(InterfaceLanguage.zhHant.rawValue, "zh-Hant")
        XCTAssertEqual(InterfaceLanguage.english.nativeName, "English")
        XCTAssertEqual(InterfaceLanguage.zhHant.nativeName, "繁體中文")
        for language in InterfaceLanguage.allCases {
            XCTAssertEqual(language.id, language.rawValue)
            XCTAssertEqual(try JSONDecoder().decode(InterfaceLanguage.self,
                from: JSONEncoder().encode(language)), language)
        }
        XCTAssertNil(InterfaceLanguage(rawValue: "unsupported"))
    }

    func testExplicitLanguageDoesNotChangeSystemLanguageOrWritingPreference() {
        let before = UserDefaults.standard.object(forKey: "AppleLanguages") as? [String]
        let writingPreference = DictationLanguagePreference()
        XCTAssertEqual(AppLocalizer(language: .english).text("navigation.home"), "Get started")
        XCTAssertEqual(AppLocalizer(language: .zhHant).text("navigation.home"), "開始使用")
        XCTAssertEqual(AppLocalizer(language: .english).text("navigation.home"), "Get started")
        XCTAssertEqual(UserDefaults.standard.object(forKey: "AppleLanguages") as? [String], before)
        XCTAssertEqual(writingPreference.selection, .traditionalChinese)
    }

    func testStringAndNumericArgumentsInBothLanguages() {
        let english = AppLocalizer(language: .english)
        let chinese = AppLocalizer(language: .zhHant)
        XCTAssertEqual(english.text("home.speak.detail", arguments: ["⌘K 100%"]),
                       "Hold ⌘K 100% to record. Release to finish.")
        XCTAssertEqual(chinese.text("home.speak.detail", arguments: ["⌘K 100%"]),
                       "按住 ⌘K 100% 錄音，放開即完成。")
        XCTAssertEqual(english.text("recording.elapsed", arguments: [1.5]), "1.5 s / 120 s")
        XCTAssertEqual(chinese.text("recording.elapsed", arguments: [1.5]), "1.5 秒／120 秒")
        XCTAssertTrue(english.text("about.license", arguments: ["test-build"]).contains("OpenInsert test-build"))
        XCTAssertTrue(chinese.text("about.license", arguments: ["test-build"]).contains("OpenInsert test-build"))
    }

    func testMissingKeyAndTableReturnTheKey() {
        for language in InterfaceLanguage.allCases {
            let localizer = AppLocalizer(language: language)
            XCTAssertEqual(localizer.text("missing.translation.fixture"), "missing.translation.fixture")
            XCTAssertEqual(localizer.text("missing.translation.fixture", table: "MissingTable"),
                           "missing.translation.fixture")
        }
    }

    func testEnglishFallbackForMissingEntryAndNonDefaultTable() throws {
        let (directory, bundle) = try fixtureBundle(includeChinese: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let localizer = AppLocalizer(language: .zhHant, resourceBundle: bundle)
        XCTAssertEqual(localizer.text("translated"), "已翻譯")
        XCTAssertEqual(localizer.text("fallback", arguments: ["sample"]), "English sample")
        XCTAssertEqual(localizer.text("status", table: "FixtureStatus"), "English status")
        XCTAssertEqual(localizer.text("missing"), "missing")
    }

    func testEnglishFallbackWhenSelectedLanguageFolderIsMissing() throws {
        let (directory, bundle) = try fixtureBundle(includeChinese: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(AppLocalizer(language: .zhHant, resourceBundle: bundle)
            .text("fallback", arguments: ["sample"]), "English sample")
    }

    func testCanonicalLocaleFolderSpellingLoadsChineseInsteadOfEnglishFallback() throws {
        for folder in ["zh-hant", "ZH_hANT"] {
            let (directory, bundle) = try fixtureBundle(includeChinese: true, chineseFolderName: folder)
            defer { try? FileManager.default.removeItem(at: directory) }
            let resolved = try XCTUnwrap(AppLocalizer.languageDirectory(.zhHant, in: bundle))
            XCTAssertEqual(resolved.lastPathComponent, folder + ".lproj")
            XCTAssertEqual(AppLocalizer(language: .zhHant, resourceBundle: bundle).text("translated"),
                           "已翻譯", "Must not silently fall back to English for \(folder)")
        }
    }

    func testPackagedAppLoadsResourcesWithoutDevelopmentBundle() throws {
        let (directory, bundle) = try fixtureApp(includeResources: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var usedDevelopmentFallback = false
        let resolved = AppLocalizer.resolveResources(in: bundle) {
            usedDevelopmentFallback = true
            return bundle
        }
        XCTAssertFalse(usedDevelopmentFallback)
        XCTAssertEqual(AppLocalizer(language: .zhHant, resourceBundle: resolved).text("translated"), "已翻譯")
        XCTAssertEqual(resolved.bundleURL.lastPathComponent, "OpenInsert_OpenInsertCore.bundle")
    }

    func testMissingInstalledResourcesDoNotEvaluateFatalDevelopmentAccessor() throws {
        let (directory, bundle) = try fixtureApp(includeResources: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var usedDevelopmentFallback = false
        let resolved = AppLocalizer.resolveResources(in: bundle) {
            usedDevelopmentFallback = true
            return bundle
        }
        XCTAssertFalse(usedDevelopmentFallback)
        XCTAssertEqual(AppLocalizer(language: .zhHant, resourceBundle: resolved).text("missing"), "missing")
    }

    func testEveryLanguageHasTheSameNonemptyTablesAndKeys() throws {
        let baseline = try tables(for: .english)
        XCTAssertFalse(baseline.isEmpty)
        XCTAssertNotNil(baseline["Interface"])
        for language in InterfaceLanguage.allCases {
            let localized = try tables(for: language)
            XCTAssertEqual(Set(localized.keys), Set(baseline.keys), language.rawValue)
            for (table, values) in baseline {
                let translated = try XCTUnwrap(localized[table])
                XCTAssertFalse(values.isEmpty, table)
                XCTAssertEqual(Set(translated.keys), Set(values.keys), "\(language.rawValue)/\(table)")
                for (key, value) in translated {
                    XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                   "\(language.rawValue)/\(table)/\(key)")
                    XCTAssertEqual(AppLocalizer(language: language).text(key, table: table), value,
                                   "Resource was not loaded explicitly: \(language.rawValue)/\(table)/\(key)")
                }
            }
        }
    }

    func testFormatArgumentsMatchAcrossEveryResourceTable() throws {
        let baseline = try tables(for: .english)
        for language in InterfaceLanguage.allCases {
            let localized = try tables(for: language)
            for (table, values) in baseline {
                for (key, english) in values {
                    let translated = try XCTUnwrap(localized[table]?[key])
                    XCTAssertEqual(try formatArguments(english), try formatArguments(translated),
                                   "Format mismatch: \(language.rawValue)/\(table)/\(key)")
                }
            }
        }
    }

    func testMainViewLiteralKeysAndWritingLanguageNamesExist() throws {
        let interface = try XCTUnwrap(tables(for: .english)["Interface"])
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repository.appendingPathComponent("Sources/OpenInsert/MainView.swift"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"\bl\("([^"]+)"\s*[,)]"#)
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        XCTAssertGreaterThan(matches.count, 50)
        for match in matches {
            let key = String(source[try XCTUnwrap(Range(match.range(at: 1), in: source))])
            XCTAssertNotNil(interface[key], "MainView references missing key: \(key)")
        }
        for language in DictationLanguage.allCases {
            XCTAssertNotNil(interface["dictation.language." + language.rawValue])
        }
    }

    private func tables(for language: InterfaceLanguage) throws -> [String: [String: String]] {
        let directory = try XCTUnwrap(AppLocalizer.languageDirectory(language, in: AppLocalizer.resources))
        let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                               includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: files.filter { $0.pathExtension == "strings" }.map { url in
            let data = try Data(contentsOf: url)
            let values = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: String], "Invalid strings table: \(url.lastPathComponent)")
            return (url.deletingPathExtension().lastPathComponent, values)
        })
    }

    /// Compare argument positions and ABI types, allowing translations to reorder
    /// positional arguments. Reject unsafe/unsupported printf directives early.
    private func formatArguments(_ text: String) throws -> [Int: String] {
        let regex = try NSRegularExpression(pattern: #"%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(hh|ll|h|l|L|z|t|j)?([@diuoxXfFeEgGaAcCsSp%])"#)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var coveredPercents = Set<Int>()
        var signature: [Int: String] = [:]
        var next = 1
        for match in matches {
            for offset in match.range.location..<(match.range.location + match.range.length) {
                coveredPercents.insert(offset)
            }
            let kind = (text as NSString).substring(with: match.range(at: 3))
            if kind == "%" { continue }
            let position: Int
            if match.range(at: 1).location != NSNotFound {
                position = try XCTUnwrap(Int((text as NSString).substring(with: match.range(at: 1))))
                XCTAssertGreaterThan(position, 0)
            } else { position = next; next += 1 }
            let length = match.range(at: 2).location == NSNotFound ? "" : (text as NSString).substring(with: match.range(at: 2))
            let type = length + kind
            if let existing = signature[position] { XCTAssertEqual(existing, type, text) }
            signature[position] = type
        }
        for (offset, codeUnit) in text.utf16.enumerated() where codeUnit == 37 {
            XCTAssertTrue(coveredPercents.contains(offset), "Unsupported format directive: \(text)")
        }
        return signature
    }

    private func fixtureBundle(includeChinese: Bool, chineseFolderName: String = "zh-Hant") throws -> (URL, Bundle) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenInsert-localization-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "org.openinsert.tests.\(UUID().uuidString)",
                                   "CFBundleDevelopmentRegion": "en"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("Info.plist"))
        let english = directory.appendingPathComponent("en.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: english, withIntermediateDirectories: true)
        try #"""
        "fallback" = "English %@";
        "translated" = "English translation";
        """#.write(to: english.appendingPathComponent("Interface.strings"), atomically: true, encoding: .utf8)
        try #"""
        "status" = "English status";
        """#.write(to: english.appendingPathComponent("FixtureStatus.strings"), atomically: true, encoding: .utf8)
        if includeChinese {
            let chinese = directory.appendingPathComponent(chineseFolderName + ".lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: chinese, withIntermediateDirectories: true)
            try #"""
            "translated" = "已翻譯";
            """#.write(to: chinese.appendingPathComponent("Interface.strings"), atomically: true, encoding: .utf8)
        }
        return (directory, try XCTUnwrap(Bundle(url: directory)))
    }

    private func fixtureApp(includeResources: Bool) throws -> (URL, Bundle) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenInsert-localization-\(UUID().uuidString).app", isDirectory: true)
        let contents = directory.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "org.openinsert.OpenInsert",
                                   "CFBundlePackageType": "APPL", "CFBundleDevelopmentRegion": "en"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if includeResources {
            let (fixture, _) = try fixtureBundle(includeChinese: true)
            defer { try? FileManager.default.removeItem(at: fixture) }
            try FileManager.default.copyItem(at: fixture,
                to: resources.appendingPathComponent("OpenInsert_OpenInsertCore.bundle", isDirectory: true))
        }
        return (directory, try XCTUnwrap(Bundle(url: directory)))
    }
}
