import SwiftUI
import OpenInsertCore

// Use the property wrapper across SDK versions, including SDKs that also export a State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct MainView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: SettingsStore
    var onPreviewHUD: () -> Void = {}
    @ViewState private var tab = 0
    @ViewState private var keyDraft = ""
    private let accent = Color(red: 0.20, green: 0.64, blue: 0.48)
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? l("version.development") }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "waveform").font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 56, height: 56)
                    .background(accent.gradient, in: RoundedRectangle(cornerRadius: 17))
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: "OpenInsert").font(.system(size: 29, weight: .bold, design: .rounded))
                    Text(l("app.tagline"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text(l("app.version", [version])).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .background(.quaternary, in: Capsule())
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle().fill(controller.phase == .recording ? .red : accent).frame(width: 8, height: 8)
                    Text(controller.statusTitle).font(.title3.weight(.semibold))
                    Spacer()
                    if controller.phase == .recording { Text(l("recording.elapsed", [controller.elapsed])).monospacedDigit() }
                    if controller.busy && controller.phase != .recording { ProgressView().controlSize(.small) }
                }
                Text(controller.message).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if !controller.timingSummary.isEmpty {
                    Text(controller.timingSummary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if controller.busy {
                    HStack {
                        if controller.phase == .recording {
                            Button(l("recording.finish")) { controller.finishRecording() }.buttonStyle(.borderedProminent).tint(accent)
                        }
                        if controller.phase == .polishing && !controller.testingPipeline {
                            Button(l("cleanup.skip")) { controller.skipPolishing() }
                        }
                        Button(l("common.cancel")) { controller.cancel() }.disabled(controller.phase == .inserting)
                    }
                }
                if let error = controller.hotKeyError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption) }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))

            Picker(l("navigation.page"), selection: $tab) {
                Text(l("navigation.home")).tag(0); Text(l("navigation.preferences")).tag(1); Text(l("navigation.connection")).tag(2); Text(l("navigation.about")).tag(3)
            }.pickerStyle(.segmented)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch tab {
                    case 0: home
                    case 1: preferences
                    case 2: connection
                    default: about
                    }
                }.padding(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Image(systemName: "lock.shield").foregroundStyle(accent)
                Text(l("privacy.footer")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker(l("interface.language"), selection: $settings.interfaceLanguage) {
                    ForEach(InterfaceLanguage.allCases) { language in
                        Text(language.nativeName).tag(language)
                    }
                }.pickerStyle(.menu).fixedSize()
            }
        }.padding(28).frame(minWidth: 650, minHeight: 600).tint(accent)
            .sheet(isPresented: Binding(
                get: { controller.recordingShortcut },
                set: { if !$0 { controller.cancelShortcutRecording() } }
            )) {
                ShortcutRecorderView(
                    current: settings.hotKey,
                    language: settings.interfaceLanguage,
                    errorMessage: controller.shortcutCaptureError,
                    onSave: controller.saveShortcut,
                    onCancel: controller.cancelShortcutRecording
                )
            }
    }

    private func l(_ key: String, _ arguments: [CVarArg] = []) -> String {
        settings.localizer.text(key, arguments: arguments)
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                step("1", l("home.setup.title"), l("home.setup.detail"))
                step("2", l("home.cursor.title"), l("home.cursor.detail"))
                step("3", l("home.speak.title"), l("home.speak.detail", [settings.hotKey.displayName]))
            }
            HStack {
                Label(settings.hotKey.displayName, systemImage: "keyboard").font(.headline)
                Text(l("home.gesture")).font(.caption).foregroundStyle(.secondary)
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            if !controller.liveText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(l("home.preview")).font(.caption.weight(.semibold)).foregroundStyle(accent)
                    Text(controller.liveText).font(.body).textSelection(.enabled)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Text(l("home.result")).font(.headline)
                Spacer()
                Button(l("common.clear")) { controller.clearResult() }.disabled(controller.lastText.isEmpty || controller.busy)
                Button(l("home.copy")) { controller.copyResult() }.disabled(controller.lastText.isEmpty)
            }
            TextEditor(text: $controller.lastText).font(.body).frame(minHeight: 125)
                .padding(8).background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                .accessibilityLabel(l("home.result.accessibility"))
                Text(l("home.delivery"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(l("home.test")) { controller.testInsertion() }.disabled(controller.busy)
                Spacer()
                Button(l("home.settings")) { tab = 2 }
            }
        }
    }
    private var preferences: some View {
        VStack(alignment: .leading, spacing: 18) {
            setting(l("preferences.overlay"), detail: l("preferences.overlay.detail")) {
                Button(l("preferences.overlay.preview")) { onPreviewHUD() }
            }
            setting(l("preferences.shortcut"), detail: l("preferences.shortcut.detail")) {
                HStack {
                    Label(settings.hotKey.displayName, systemImage: "keyboard")
                    Spacer()
                    Button(l("preferences.shortcut.record")) { _ = controller.beginShortcutRecording() }
                }
            }
            setting(l("preferences.mode"), detail: l("preferences.mode.detail")) {
                Picker(l("preferences.mode"), selection: $settings.mode) {
                    Text(l("preferences.mode.polished")).tag(CleanupMode.polished); Text(l("preferences.mode.verbatim")).tag(CleanupMode.verbatim)
                }.pickerStyle(.segmented).labelsHidden()
            }
            setting(l("preferences.language"), detail: l("preferences.language.detail")) {
                Picker(l("preferences.language"), selection: $settings.languageSelection) {
                    ForEach(DictationLanguage.allCases) { language in
                        Text(l("dictation.language." + language.rawValue)).tag(language)
                    }
                }.pickerStyle(.menu).labelsHidden()
                if settings.languageSelection == .custom {
                    TextField(l("preferences.language.placeholder"), text: $settings.customLanguage)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(l("preferences.language.custom"))
                    Text(l("preferences.language.legacy"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            setting(l("preferences.vocabulary"), detail: l("preferences.vocabulary.detail")) {
                TextEditor(text: $settings.vocabulary).frame(height: 80).padding(5).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .accessibilityLabel(l("preferences.vocabulary"))
            }
            Toggle(l("preferences.clipboard"), isOn: $settings.restoreClipboard)
            Text(l("preferences.clipboard.detail"))
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(controller.busy)
    }
    private var connection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(controller.hasAPIKey ? l("connection.key.saved") : l("connection.key.missing"), systemImage: controller.hasAPIKey ? "checkmark.circle.fill" : "key")
                    .font(.headline)
                Spacer()
                Link(l("connection.key.get"), destination: URL(string: "https://aistudio.google.com/apikey")!)
            }
            HStack {
                SecureField(l("connection.key.placeholder"), text: $keyDraft).textFieldStyle(.roundedBorder)
                Button(l("connection.key.save")) { if controller.saveKey(keyDraft) { keyDraft = "" } }.disabled(keyDraft.isEmpty)
                Button(l("common.delete")) { controller.deleteKey() }.disabled(!controller.hasAPIKey)
            }.disabled(controller.busy)
            setting(l("connection.asr"), detail: l("connection.asr.detail")) {
                TextField(l("connection.asr.placeholder"), text: $settings.asrModel).textFieldStyle(.roundedBorder).disabled(controller.busy)
            }
            setting(l("connection.cleanup"), detail: l("connection.cleanup.detail")) {
                TextField(l("connection.cleanup.placeholder"), text: $settings.model).textFieldStyle(.roundedBorder).disabled(controller.busy)
            }
            Toggle(l("connection.consent"), isOn: $settings.cloudConsent)
                .disabled(controller.busy)
            Button(l("connection.check")) { controller.checkConnection() }
                .disabled(controller.busy || !controller.hasAPIKey || !settings.cloudConsent)
            VStack(alignment: .leading, spacing: 7) {
                Button(l("connection.pipeline")) { controller.testPipeline() }
                    .disabled(controller.busy || !controller.hasAPIKey || !settings.cloudConsent)
                Text(l("connection.pipeline.detail"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(l("connection.terms"))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            permission(l("permission.microphone"), granted: controller.microphoneGranted, description: l("permission.microphone.detail"), action: controller.requestMicrophone)
            permission(l("permission.accessibility"), granted: controller.accessibilityGranted, description: l("permission.accessibility.detail"), action: controller.requestAccessibility)
            if !controller.accessibilityGranted {
                VStack(alignment: .leading, spacing: 6) {
                    Text(l("permission.repair"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(l("permission.path")).font(.caption.weight(.semibold))
                    Text(Bundle.main.bundlePath).font(.caption.monospaced())
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            }
            Button(l("permission.recheck")) { controller.refreshPermissions() }
        }
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l("about.title")).font(.title3.weight(.semibold))
            Text(l("about.pipeline"))
                .font(.body.monospaced()).padding(16).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            Text(l("about.privacy"))
                .font(.callout).lineSpacing(7)
            HStack {
                Link(l("about.google"), destination: URL(string: "https://ai.google.dev/gemini-api/terms")!)
                Link(l("about.models"), destination: URL(string: "https://ai.google.dev/gemini-api/docs/models")!)
            }
            Text(l("about.license", [version]))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(number).font(.caption.weight(.bold)).foregroundStyle(accent).frame(width: 24, height: 24).background(accent.opacity(0.12), in: Circle())
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func setting<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            content()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func permission(_ title: String, granted: Bool, description: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? accent : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline); Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(granted ? l("permission.enabled") : l("permission.enable")) { action() }.disabled(granted || controller.busy)
        }
    }
}
