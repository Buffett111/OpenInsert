import AppKit
import ApplicationServices
import AVFoundation
import Combine
import OpenInsertCore

@MainActor final class DictationController: ObservableObject {
    enum Phase { case idle, preparing, recording, transcribing, inserting, testing }
    @Published private(set) var phase: Phase = .idle
    @Published var message = "設定 API key 後，將游標放到輸入欄位即可開始。"
    @Published var lastText = ""
    @Published private(set) var liveText = ""
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var hasAPIKey = false
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published private(set) var hotKeyError: String?
    let settings: SettingsStore
    private let recorder = StreamingAudioRecorder()
    private let inserter = TextInserter()
    private let hotKey = GlobalHotKey()
    private var operation: Task<Void, Never>?
    private var sender: Task<Void, Error>?
    private var liveSession: GeminiLiveTranscriber?
    private var timer: Timer?
    private var target: TextInserter.Target?
    private var pressedAt: Date?
    private var stopWhenReady = false
    private var sessionKey = ""
    private var sessionOptions = DictationOptions()
    private var sessionRestore = true
    private var generation = UUID()

    init(settings: SettingsStore) {
        self.settings = settings
        refreshPermissions()
        hotKey.onPress = { [weak self] in self?.shortcutPressed() }
        hotKey.onRelease = { [weak self] in self?.shortcutReleased() }
        registerShortcut()
    }

    var busy: Bool { phase != .idle }
    var statusTitle: String {
        switch phase {
        case .idle: return "隨時開口，文字就位。"
        case .preparing: return "正在準備麥克風…"
        case .recording: return "正在即時辨識…"
        case .transcribing: return "正在完成辨識與文字整理…"
        case .inserting: return "正在插入文字…"
        case .testing: return "準備測試文字插入…"
        }
    }
    func registerShortcut() {
        do { try hotKey.register(choice: settings.hotKey); hotKeyError = nil }
        catch { hotKeyError = error.localizedDescription }
    }
    func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        do { hasAPIKey = !(try KeychainStore.load() ?? "").isEmpty }
        catch { hasAPIKey = false; message = error.localizedDescription }
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func requestMicrophone() {
        Task {
            microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
            if !microphoneGranted {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        }
    }
    @discardableResult func saveKey(_ value: String) -> Bool {
        guard !busy else { return false }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { message = "請輸入 API key。"; return false }
        do { try KeychainStore.save(key); hasAPIKey = true; message = "API key 已儲存到 macOS Keychain。"; return true }
        catch { message = error.localizedDescription; return false }
    }
    func deleteKey() {
        guard !busy else { return }
        do { try KeychainStore.delete(); hasAPIKey = false; message = "API key 已刪除。" }
        catch { message = error.localizedDescription }
    }
    private func shortcutPressed() {
        if phase == .preparing { stopWhenReady = true; pressedAt = nil; return }
        if phase == .recording { finishRecording(); pressedAt = nil; return }
        guard phase == .idle else { return }
        pressedAt = Date()
        startRecording()
    }
    private func shortcutReleased() {
        guard let pressedAt else { return }
        self.pressedAt = nil
        if Date().timeIntervalSince(pressedAt) >= 0.35 {
            if phase == .preparing { stopWhenReady = true }
            else if phase == .recording { finishRecording() }
        }
    }
    func startRecording() {
        guard phase == .idle else { return }
        guard settings.cloudConsent else {
            message = "請先在設定同意將你主動錄製的音訊傳送到 Google Gemini。"; return
        }
        do {
            guard let key = try KeychainStore.load(), !key.isEmpty else {
                message = "請先在設定儲存自己的 Gemini API key。"; return
            }
            sessionKey = key
        } catch { message = error.localizedDescription; return }
        do { target = try inserter.captureTarget() }
        catch { target = nil }
        sessionOptions = settings.options
        sessionRestore = settings.restoreClipboard
        stopWhenReady = false
        phase = .preparing
        let token = UUID(); generation = token
        liveText = ""
        let client = GeminiLiveTranscriber(apiKey: sessionKey, model: settings.asrModel,
            languageCodes: [], vocabulary: settings.vocabulary.split(whereSeparator: \.isNewline).map(String.init),
            onPartial: { [weak self] text in
                Task { @MainActor in
                    guard let self, self.generation == token, self.busy else { return }
                    self.liveText = text
                }
            })
        liveSession = client
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await recorder.start()
                guard generation == token, !Task.isCancelled else { return }
                phase = .recording
                message = target == nil ? "音訊正串流至 Google；這次將保留結果供手動複製。" : "音訊正串流至 Google。放開快捷鍵結束；短按可切換錄音。"
                sender = Task { [weak self] in
                    do {
                        try await client.start()
                        for try await chunk in stream {
                            try Task.checkCancellation()
                            try await client.sendAudio(chunk)
                        }
                    } catch {
                        await client.cancel()
                        if let self, self.generation == token, self.phase == .recording {
                            self.recorder.cancel()
                            self.reset(message: error.localizedDescription)
                        }
                        throw error
                    }
                }
                elapsed = 0
                microphoneGranted = true
                timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.phase == .recording else { return }
                        self.elapsed = self.recorder.duration
                        self.level = self.recorder.level
                        if self.elapsed >= 119 { self.finishRecording() }
                    }
                }
                if stopWhenReady { finishRecording() }
            } catch {
                await client.cancel()
                guard generation == token else { return }
                reset(message: error.localizedDescription)
            }
        }
    }
    func finishRecording() {
        guard phase == .recording else { return }
        timer?.invalidate(); timer = nil
        guard let client = liveSession, let sending = sender else { cancel(); return }
        let duration = recorder.duration
        recorder.stop()
        guard duration >= 0.35 else { cancel(); message = "錄音太短，請再試一次。"; return }
        phase = .transcribing
        message = "正在等待 Live ASR 的最後片段。"
        let key = sessionKey; sessionKey = ""
        let options = sessionOptions
        let capturedTarget = target
        let restore = sessionRestore
        let token = generation
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                // Drain every recorded chunk before sending the end-of-activity marker.
                try await sending.value
                let raw = options.applyingOrthography(to: try await client.finish())
                try Task.checkCancellation()
                guard generation == token else { return }
                lastText = raw
                liveText = ""
                var text = raw
                if options.mode == .polished {
                    message = "Live 辨識完成，正在使用 \(options.model) 輕度整理。"
                    text = try await GeminiClient().polish(transcript: raw, apiKey: key, options: options)
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                lastText = text
                guard let capturedTarget else {
                    reset(message: "辨識完成。未取得輸入位置，請複製下方結果。"); return
                }
                phase = .inserting
                let method = try await inserter.insert(text, into: capturedTarget, restoreClipboard: restore)
                guard generation == token else { return }
                reset(message: method)
            } catch {
                await client.cancel()
                guard generation == token else { return }
                reset(message: error is CancellationError ? "已取消。已送出的音訊無法收回。" : "\(error.localizedDescription) 已完成的辨識結果仍保留供複製。")
            }
        }
    }
    func cancel() {
        guard phase != .inserting else { return }
        generation = UUID()
        operation?.cancel(); operation = nil
        sender?.cancel(); sender = nil
        if let client = liveSession { Task { await client.cancel() } }
        recorder.cancel()
        reset(message: "已取消；本機音訊緩衝已釋放，已傳送至 Google 的音訊無法收回。")
    }
    private func reset(message: String) {
        timer?.invalidate(); timer = nil
        sessionKey = ""; target = nil; stopWhenReady = false; pressedAt = nil
        liveSession = nil; sender = nil
        phase = .idle; level = 0
        self.message = message
    }
    func copyResult() {
        guard !lastText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastText, forType: .string)
        message = "結果已複製。"
    }
    func clearResult() { lastText = ""; message = "已清除記憶體中的辨識結果。" }
    func testInsertion() {
        guard !busy else { return }
        phase = .testing
        let token = UUID(); generation = token
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                for second in (1...5).reversed() {
                    message = "請在 \(second) 秒內將游標放到測試輸入欄位。"
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                try Task.checkCancellation()
                let captured = try inserter.captureTarget()
                let test = "OpenInsert 文字插入測試成功。"
                lastText = test
                phase = .inserting
                let method = try await inserter.insert(test, into: captured, restoreClipboard: settings.restoreClipboard)
                guard generation == token else { return }
                reset(message: method)
            } catch {
                guard generation == token else { return }
                reset(message: error.localizedDescription)
            }
        }
    }
    func shutdown() {
        operation?.cancel(); sender?.cancel()
        if let client = liveSession { Task { await client.cancel() } }
        recorder.cancel(); timer?.invalidate(); hotKey.unregister()
    }
}
