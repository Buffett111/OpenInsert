import AppKit
import SwiftUI
import Combine

@main struct OpenInsertApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var controller: DictationController!
    private var dictationHUD: DictationHUD?
    private var subscriptions = Set<AnyCancellable>()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let settings = SettingsStore()
        controller = DictationController(settings: settings)
        let hud = DictationHUD(controller: controller)
        dictationHUD = hud
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "OpenInsert"
        window.minSize = NSSize(width: 700, height: 660)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: MainView(controller: controller, settings: settings,
            onPreviewHUD: { [weak hud] in hud?.showPreview() }))
        window.center()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "開啟 OpenInsert…", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: "停止錄音", action: #selector(stopRecording), keyEquivalent: "")
        menu.addItem(withTitle: "取消目前操作", action: #selector(cancelOperation), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "結束 OpenInsert", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
        controller.$phase.sink { [weak self] phase in
            guard let self else { return }
            let recording = phase == .recording
            self.statusItem.button?.image = NSImage(systemSymbolName: recording ? "record.circle.fill" : "waveform", accessibilityDescription: "OpenInsert")
            self.statusItem.button?.contentTintColor = recording ? .systemRed : nil
            self.statusItem.button?.title = recording ? " REC" : (phase == .transcribing || phase == .polishing ? " …" : "")
            menu.items[1].isEnabled = recording
            menu.items[2].isEnabled = phase != .idle && phase != .inserting
        }.store(in: &subscriptions)
        showWindow()
        // A reproducible diagnostic entry point for contributors and support.
        // It exercises the same fixed-sentence path as the UI, never the microphone.
        if ProcessInfo.processInfo.arguments.contains("--diagnose-pipeline") {
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.controller.hasAPIKey, self.controller.settings.cloudConsent else {
                    self.printDiagnostic(success: false, status: "Save an API key and consent to Google in OpenInsert first.")
                    NSApp.terminate(nil)
                    return
                }
                self.controller.testPipeline()
                let deadline = ProcessInfo.processInfo.systemUptime + 70
                while self.controller.busy, ProcessInfo.processInfo.systemUptime < deadline {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                let expired = self.controller.busy
                if expired { self.controller.cancel() }
                self.printDiagnostic(success: !expired && self.controller.lastFailure == nil,
                    status: expired ? "Diagnostic exceeded its overall deadline." : self.controller.message)
                NSApp.terminate(nil)
            }
        }
    }
    private func printDiagnostic(success: Bool, status: String) {
        let report: [String: Any] = ["success": success, "status": status,
            "timing": controller.timingSummary, "syntheticResult": controller.lastText,
            "microphoneUsed": false, "textInserted": false]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { print(line) }
    }
    @objc func showWindow() {
        controller.refreshPermissions()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    @objc func stopRecording() { controller.finishRecording() }
    @objc func cancelOperation() { controller.cancel() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.phase == .inserting else { return .terminateNow }
        Task { @MainActor in
            while controller.phase == .inserting {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationDidBecomeActive(_ notification: Notification) { controller?.refreshPermissions() }
    func applicationWillTerminate(_ notification: Notification) {
        dictationHUD?.close()
        controller?.shutdown()
    }
}
