import Foundation
import XCTest
@testable import OpenInsertCore

final class DictationLanguageTests: XCTestCase {
    func testNewSettingsDefaultToTraditionalChineseWithMixedLanguagePreservation() {
        let preference = DictationLanguagePreference()
        XCTAssertEqual(preference.selection, .traditionalChinese)
        XCTAssertEqual(preference.customText, "")
        XCTAssertTrue(preference.hint.contains("mixed Chinese and English"))
        XCTAssertTrue(preference.hint.contains("Do not translate"))
    }

    func testLegacyDefaultAndKnownLabelsMigrateToPresets() {
        let cases: [(String, DictationLanguage)] = [
            ("Traditional Chinese (Taiwan), preserve spoken English", .traditionalChinese),
            ("繁體中文", .traditionalChinese), ("zh-Hant", .traditionalChinese),
            ("Automatic", .automatic), ("简体中文", .simplifiedChinese),
            (" English ", .english), ("日本語", .japanese), ("한국어", .korean)
        ]
        for (legacy, expected) in cases {
            XCTAssertEqual(DictationLanguagePreference(legacyLanguage: legacy).selection, expected, legacy)
        }
    }

    func testLegacyCustomTextIsPreservedExactlyRatherThanMatchedBySubstring() {
        let custom = "  British English; preserve Traditional Chinese names\nand all acronyms.  "
        let preference = DictationLanguagePreference(legacyLanguage: custom)
        XCTAssertEqual(preference.selection, .custom)
        XCTAssertEqual(preference.customText, custom)
        XCTAssertEqual(preference.hint, custom)
        XCTAssertNil(DictationLanguage.matchingPreset(for: custom))
    }

    func testPresetRoundTripRetainsSeparateCustomDraft() {
        let preference = DictationLanguagePreference(storedSelection: "english",
            storedCustomText: "保留廣東話用字", legacyLanguage: "stale language")
        XCTAssertEqual(preference.selection, .english)
        XCTAssertEqual(preference.customText, "保留廣東話用字")
        var edited = preference
        edited.selection = .custom
        XCTAssertEqual(edited.hint, "保留廣東話用字")
    }

    func testUnknownStoredSelectionFallsBackToPreservedLegacyCustom() {
        let preference = DictationLanguagePreference(storedSelection: "future-option", legacyLanguage: "fr-CA")
        XCTAssertEqual(preference.selection, .custom)
        XCTAssertEqual(preference.customText, "fr-CA")
    }

    func testStoredEmptyCustomDoesNotResurrectStaleLegacyText() {
        let preference = DictationLanguagePreference(storedSelection: "custom", storedCustomText: "",
            legacyLanguage: "Old preference")
        XCTAssertEqual(preference.selection, .custom)
        XCTAssertEqual(preference.customText, "")
        XCTAssertEqual(preference.hint, DictationLanguage.automatic.promptHint)
    }

    func testAllPresetHintsRoundTripAndForbidTranslation() {
        for language in DictationLanguage.allCases where language != .custom {
            XCTAssertEqual(DictationLanguage.matchingPreset(for: language.promptHint), language)
            XCTAssertTrue(language.promptHint.contains("Do not translate"))
        }
    }

    func testTraditionalAndSimplifiedConvertOnlyCharacterForms() {
        let traditional = DictationOptions(languagePreference: .traditionalChinese)
        XCTAssertEqual(traditional.applyingOrthography(to: "语音输入 OpenInsert API 123"), "語音輸入 OpenInsert API 123")
        let simplified = DictationOptions(language: DictationLanguage.simplifiedChinese.promptHint,
            languagePreference: .simplifiedChinese)
        XCTAssertEqual(simplified.applyingOrthography(to: "語音輸入 OpenInsert API 123"), "语音输入 OpenInsert API 123")
        XCTAssertEqual(DictationOptions(language: "zh-TW").applyingOrthography(to: "语音"), "語音")
    }

    func testAutomaticEnglishJapaneseKoreanAndCustomPreserveMixedScriptText() {
        let original = "语音輸入 English 日本語の図書館 한국어 API 123"
        for selection in [DictationLanguage.automatic, .english, .japanese, .korean, .custom] {
            let options = DictationOptions(language: selection.promptHint, languagePreference: selection)
            XCTAssertEqual(options.applyingOrthography(to: original), original, selection.rawValue)
        }
    }
}
