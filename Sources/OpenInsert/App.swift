import AppKit
import SwiftUI
import Combine
import OpenInsertCore

@main enum OpenInsertApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // NSApplication holds its delegate weakly. The AppKit lifetime owns the
        // single hosting window; no SwiftUI Settings scene creates a second one.
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var controller: DictationController!
    private var dictationHUD: DictationHUD?
    private var subscriptions = Set<AnyCancellable>()
    private var localizedMainMenuItems: [(NSMenuItem, String)] = []
    private var localizedMainMenus: [(NSMenu, String)] = []
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
        menu.addItem(withTitle: settings.localizer.text("menu.open", table: "Status"), action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: settings.localizer.text("menu.stop", table: "Status"), action: #selector(stopRecording), keyEquivalent: "")
        menu.addItem(withTitle: settings.localizer.text("menu.cancel", table: "Status"), action: #selector(cancelOperation), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: settings.localizer.text("menu.quit", table: "Status"), action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
        installMainMenu()
        settings.$interfaceLanguage.removeDuplicates().sink { [weak self] language in
            let localizer = AppLocalizer(language: language)
            for (index, key) in [(0, "menu.open"), (1, "menu.stop"), (2, "menu.cancel"), (4, "menu.quit")] {
                menu.items[index].title = localizer.text(key, table: "Status")
            }
            self?.localizeMainMenu(using: localizer)
        }.store(in: &subscriptions)
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
                    self.printDiagnostic(success: false, status: self.controller.settings.localizer.text("cli.setup", table: "Status"))
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
                    status: expired ? self.controller.settings.localizer.text("cli.timeout", table: "Status") : self.controller.message)
                NSApp.terminate(nil)
            }
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu(title: "OpenInsert")
        let appItem = NSMenuItem(title: "OpenInsert", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "OpenInsert")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        appMenu.addItem(mainMenuItem("menu.settings", action: #selector(showWindow), key: ",", target: self))
        appMenu.addItem(.separator())
        appMenu.addItem(mainMenuItem("menu.hide", action: #selector(NSApplication.hide(_:)), key: "h", target: NSApp))
        appMenu.addItem(mainMenuItem("menu.hideOthers", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option], target: NSApp))
        appMenu.addItem(mainMenuItem("menu.showAll", action: #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
        appMenu.addItem(.separator())
        appMenu.addItem(mainMenuItem("menu.quit", action: #selector(quit), key: "q", target: self))

        let fileMenu = mainSubmenu("menu.file", in: mainMenu)
        fileMenu.addItem(mainMenuItem("menu.close", action: #selector(NSWindow.performClose(_:)), key: "w"))

        let editMenu = mainSubmenu("menu.edit", in: mainMenu)
        // Nil targets use the responder chain, including SwiftUI text editors
        // and the secure API-key field. AppKit controls their enabled state.
        editMenu.addItem(mainMenuItem("menu.undo", action: NSSelectorFromString("undo:"), key: "z"))
        editMenu.addItem(mainMenuItem("menu.redo", action: NSSelectorFromString("redo:"), key: "z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(mainMenuItem("menu.cut", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(mainMenuItem("menu.copy", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(mainMenuItem("menu.paste", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(mainMenuItem("menu.delete", action: #selector(NSText.delete(_:))))
        editMenu.addItem(.separator())
        editMenu.addItem(mainMenuItem("menu.selectAll", action: #selector(NSText.selectAll(_:)), key: "a"))

        let windowMenu = mainSubmenu("menu.window", in: mainMenu)
        windowMenu.addItem(mainMenuItem("menu.minimize", action: #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        windowMenu.addItem(mainMenuItem("menu.zoom", action: #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(mainMenuItem("menu.bringAllToFront", action: #selector(NSApplication.arrangeInFront(_:)), target: NSApp))
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private func mainMenuItem(_ key: String, action: Selector?, key equivalent: String = "",
                              modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: controller.settings.localizer.text(key, table: "Status"), action: action, keyEquivalent: equivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        localizedMainMenuItems.append((item, key))
        return item
    }

    private func mainSubmenu(_ key: String, in parent: NSMenu) -> NSMenu {
        let item = mainMenuItem(key, action: nil)
        let menu = NSMenu(title: item.title)
        item.submenu = menu
        parent.addItem(item)
        localizedMainMenus.append((menu, key))
        return menu
    }

    private func localizeMainMenu(using localizer: AppLocalizer) {
        for (item, key) in localizedMainMenuItems { item.title = localizer.text(key, table: "Status") }
        for (menu, key) in localizedMainMenus { menu.title = localizer.text(key, table: "Status") }
    }

    private func printDiagnostic(success: Bool, status: String) {
        let report: [String: Any] = ["success": success, "status": status,
            "timing": controller.timingSummary, "syntheticResult": controller.lastText,
            "microphoneUsed": false, "textInserted": false]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { print(line) }
    }
    @objc func showWindow() {
        guard let window, let controller else { return }
        controller.refreshPermissions()
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false // The existing window handled this request.
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @objc func stopRecording() { controller.finishRecording() }
    @objc func cancelOperation() { controller.cancel() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller, controller.phase == .inserting else { return .terminateNow }
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
