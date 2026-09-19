// Standalone macOS integration harness. Compile alongside GlobalHotKey.swift
// and link OpenInsertCore. It registers uncommon keys briefly, sends no key
// events, opens no windows, and releases every registration on exit.
import AppKit
import Carbon
import OpenInsertCore

@main
struct ShortcutRegistrationHarness {
    @MainActor
    static func main() {
        do { try run() }
        catch {
            fputs("Registration harness could not complete: \(error)\n", stderr)
            exit(2)
        }
    }

    @MainActor
    private static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let first = GlobalHotKey()
        let second = GlobalHotKey()
        let probe = GlobalHotKey()
        defer { first.unregister(); second.unregister(); probe.unregister() }
        let original = OpenInsertCore.KeyboardShortcut(keyCode: 64, modifiers: .all) // F17
        let occupied = OpenInsertCore.KeyboardShortcut(keyCode: 79, modifiers: .all) // F18
        try first.register(shortcut: original)
        try second.register(shortcut: occupied)
        try expectConflict { try first.register(shortcut: occupied) }
        try expectConflict { try probe.register(shortcut: original) }
        // Re-registering the current combination is an idempotent no-op.
        try first.register(shortcut: original)
        first.unregister()
        try probe.register(shortcut: original)
        print("PASS: conflicting candidate preserves original registration; identical registration is a no-op; unregister releases the original key.")
    }

    @MainActor
    private static func expectConflict(_ body: () throws -> Void) throws {
        do {
            try body()
            throw HarnessError.unexpectedSuccess
        } catch let error as GlobalHotKey.HotKeyError {
            guard error.status == OSStatus(eventHotKeyExistsErr) else { throw error }
        }
    }

    private enum HarnessError: Error { case unexpectedSuccess }
}
