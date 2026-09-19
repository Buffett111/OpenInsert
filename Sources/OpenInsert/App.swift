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
    private var subscriptions = Set<AnyCancellable>()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let settings = SettingsStore()
        controller = DictationController(settings: settings)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "OpenInsert"
        window.minSize = NSSize(width: 700, height: 660)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: MainView(controller: controller, settings: settings))
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
            self.statusItem.button?.title = recording ? " REC" : (phase == .transcribing ? " …" : "")
            menu.items[1].isEnabled = recording
            menu.items[2].isEnabled = phase != .idle && phase != .inserting
        }.store(in: &subscriptions)
        showWindow()
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
    func applicationWillTerminate(_ notification: Notification) { controller?.shutdown() }
}
