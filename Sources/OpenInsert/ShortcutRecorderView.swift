import AppKit
import SwiftUI
import OpenInsertCore

private typealias RecorderState<Value> = SwiftUI.State<Value>

/// A sheet-local recorder, never a global event monitor or keyboard tap.
struct ShortcutRecorderView: View {
    let current: OpenInsertCore.KeyboardShortcut
    let language: InterfaceLanguage
    let errorMessage: String?
    let onSave: (OpenInsertCore.KeyboardShortcut) -> Bool
    let onCancel: () -> Void
    @RecorderState private var candidate: OpenInsertCore.KeyboardShortcut?
    @RecorderState private var validationError: OpenInsertCore.KeyboardShortcut.ValidationError?
    @RecorderState private var completed = false
    @RecorderState private var capturing = true

    private var localizer: AppLocalizer { AppLocalizer(language: language) }
    private func text(_ key: String) -> String { localizer.text(key, table: "Shortcuts") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(text("shortcut.title"), systemImage: "keyboard").font(.title2.weight(.semibold))
            Text(text("shortcut.instructions")).font(.callout).foregroundStyle(.secondary)
            Text(candidate?.displayName ?? text("shortcut.listening"))
                .font(.title.monospaced()).frame(maxWidth: .infinity, minHeight: 64)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel(text("shortcut.candidate"))
            Text(localizer.text("shortcut.current", table: "Shortcuts", arguments: [current.displayName]))
                .font(.caption).foregroundStyle(.secondary)
            if let validationError {
                Text(text(validationError.localizationKey)).font(.callout).foregroundStyle(.orange)
            } else if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.orange)
            }
            Text(text("shortcut.privacy")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(text("shortcut.default")) { candidate = .optionSpace; validationError = nil; capturing = false }
                if !capturing {
                    Button(text("shortcut.recordAgain")) { candidate = nil; validationError = nil; capturing = true }
                }
            }
            HStack {
                Spacer()
                Button(text("shortcut.cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(text("shortcut.save")) {
                    guard let candidate, candidate.validationError == nil else { return }
                    if onSave(candidate) { completed = true }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(candidate == nil || validationError != nil)
            }
        }
        .padding(24).frame(width: 440)
        .background(ShortcutCaptureHost(isRecording: { !completed }, isCapturing: { capturing }, onKey: capture, onCancel: cancel).frame(width: 0, height: 0))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in cancel() }
        .onDisappear { if !completed { cancel() } }
    }

    private func capture(_ shortcut: OpenInsertCore.KeyboardShortcut) {
        guard !completed else { return }
        if let failure = shortcut.validationError {
            candidate = nil
            validationError = failure
        } else {
            candidate = shortcut
            validationError = nil
            capturing = false
        }
    }

    private func cancel() {
        guard !completed else { return }
        completed = true
        onCancel()
    }
}

private struct ShortcutCaptureHost: NSViewRepresentable {
    let isRecording: () -> Bool
    let isCapturing: () -> Bool
    let onKey: (OpenInsertCore.KeyboardShortcut) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.isRecording = isRecording
        view.isCapturing = isCapturing
        view.onKey = onKey
        view.onCancel = onCancel
        return view
    }
    func updateNSView(_ view: ShortcutCaptureNSView, context: Context) {
        view.isRecording = isRecording
        view.isCapturing = isCapturing
        view.onKey = onKey
        view.onCancel = onCancel
    }
    static func dismantleNSView(_ view: ShortcutCaptureNSView, coordinator: ()) { view.stop() }
}

private final class ShortcutCaptureNSView: NSView {
    var isRecording: (() -> Bool)?
    var isCapturing: (() -> Bool)?
    var onKey: ((OpenInsertCore.KeyboardShortcut) -> Void)?
    var onCancel: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording?() == true, let window = self.window, NSApp.isActive,
                  NSApp.keyWindow === window,
                  event.window == nil || event.window === window else { return event }
            // Only this foreground sheet consumes events. Repeats cannot replace
            // a candidate, and Escape always cancels without changing settings.
            if event.keyCode == 53 { self.onCancel?(); return nil }
            guard self.isCapturing?() == true else { return event }
            guard !event.isARepeat else { return nil }
            var modifiers: OpenInsertCore.KeyboardShortcut.Modifiers = []
            if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
            if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
            if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
            if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            self.onKey?(.init(keyCode: UInt32(event.keyCode), modifiers: modifiers))
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
