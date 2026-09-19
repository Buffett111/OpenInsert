import Foundation

/// A physical macOS key code and portable modifier bits. No typed text is stored.
public struct KeyboardShortcut: Codable, Equatable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let command = Self(rawValue: 1 << 0)
        public static let option = Self(rawValue: 1 << 1)
        public static let control = Self(rawValue: 1 << 2)
        public static let shift = Self(rawValue: 1 << 3)
        public static let all: Self = [.command, .option, .control, .shift]
    }

    public let keyCode: UInt32
    public let modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let optionSpace = Self(keyCode: 49, modifiers: .option)

    public static func legacyMigration(rawValue: String?) -> Self {
        switch rawValue {
        case "controlOptionSpace": return Self(keyCode: 49, modifiers: [.control, .option])
        case "controlShiftSpace": return Self(keyCode: 49, modifiers: [.control, .shift])
        default: return .optionSpace
        }
    }

    public enum ValidationError: String, Error, LocalizedError, Sendable {
        case unsupportedKey, modifierKey, escapeReserved, modifierRequired, unknownModifiers
        public var localizationKey: String { "shortcut.validation." + rawValue }
        public var errorDescription: String? {
            switch self {
            case .unsupportedKey: return "This key is not supported. Choose a regular key or F1–F20."
            case .modifierKey: return "Press a regular key together with the modifiers."
            case .escapeReserved: return "Escape is reserved for cancelling shortcut recording."
            case .modifierRequired: return "Include Command, Option or Control. Function keys F1–F20 can be used alone."
            case .unknownModifiers: return "This modifier combination is not supported."
            }
        }
    }

    public var validationError: ValidationError? {
        guard modifiers.rawValue & ~Modifiers.all.rawValue == 0 else { return .unknownModifiers }
        guard keyCode <= 127 else { return .unsupportedKey }
        if [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode) { return .modifierKey }
        if keyCode == 53 { return .escapeReserved }
        let functionKeys: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        if modifiers.intersection([.command, .option, .control]).isEmpty && !functionKeys.contains(keyCode) {
            return .modifierRequired
        }
        return nil
    }

    public func validate() throws {
        if let validationError { throw validationError }
    }
}
