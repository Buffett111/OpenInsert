import XCTest
@testable import OpenInsertCore

final class KeyboardShortcutTests: XCTestCase {
    func testLegacySettingsKeepTheirExactCombination() {
        XCTAssertEqual(KeyboardShortcut.legacyMigration(rawValue: "optionSpace"), .optionSpace)
        XCTAssertEqual(KeyboardShortcut.legacyMigration(rawValue: "controlOptionSpace"), .init(keyCode: 49, modifiers: [.control, .option]))
        XCTAssertEqual(KeyboardShortcut.legacyMigration(rawValue: "controlShiftSpace"), .init(keyCode: 49, modifiers: [.control, .shift]))
        XCTAssertEqual(KeyboardShortcut.legacyMigration(rawValue: nil), .optionSpace)
        XCTAssertEqual(KeyboardShortcut.legacyMigration(rawValue: "unknown"), .optionSpace)
    }

    func testCustomPhysicalKeyAndAllModifiersSurviveJSONRoundTrip() throws {
        let shortcut = KeyboardShortcut(keyCode: 40, modifiers: [.command, .control, .option, .shift])
        let decoded = try JSONDecoder().decode(KeyboardShortcut.self, from: JSONEncoder().encode(shortcut))
        XCTAssertEqual(decoded, shortcut)
        XCTAssertNil(decoded.validationError)
        XCTAssertEqual(Set([shortcut, decoded]).count, 1)
    }

    func testOrdinaryTypingAndShiftAloneCannotBecomeGlobalShortcuts() {
        for key: UInt32 in [0, 36, 48, 49, 51, 123] {
            XCTAssertEqual(KeyboardShortcut(keyCode: key, modifiers: []).validationError, .modifierRequired)
            XCTAssertEqual(KeyboardShortcut(keyCode: key, modifiers: .shift).validationError, .modifierRequired)
            for modifier: KeyboardShortcut.Modifiers in [.command, .option, .control] {
                XCTAssertNil(KeyboardShortcut(keyCode: key, modifiers: modifier).validationError)
            }
        }
    }

    func testF1ThroughF20CanBeUsedWithoutModifiers() {
        let keys: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for key in keys { XCTAssertNil(KeyboardShortcut(keyCode: key, modifiers: []).validationError) }
    }

    func testPhysicalModifiersAndEscapeCannotBeRecordedAsMainKey() {
        for key: UInt32 in [54, 55, 56, 57, 58, 59, 60, 61, 62, 63] {
            XCTAssertEqual(KeyboardShortcut(keyCode: key, modifiers: .command).validationError, .modifierKey)
        }
        XCTAssertEqual(KeyboardShortcut(keyCode: 53, modifiers: .command).validationError, .escapeReserved)
    }

    func testMalformedStoredValuesAreRejectedBeforeCarbonConversion() {
        XCTAssertEqual(KeyboardShortcut(keyCode: .max, modifiers: .command).validationError, .unsupportedKey)
        XCTAssertEqual(KeyboardShortcut(keyCode: 49, modifiers: .init(rawValue: 1 << 30)).validationError, .unknownModifiers)
        XCTAssertThrowsError(try KeyboardShortcut(keyCode: 128, modifiers: .command).validate())
    }
}
