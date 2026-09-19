import AppKit
import ApplicationServices
import AVFoundation
import Combine
import OpenInsertCore

@MainActor final class DictationController: ObservableObject {
    enum Phase { case idle, preparing, recording, transcribing, polishing, inserting, testing }
    @Published private(set) var phase: Phase = .idle
    @Published var message = "設定 API key 後，將游標放到輸入欄位即可開始。"
    @Published var lastText = ""
    @Published private(set) var liveText = ""
    @Published private(set) var liveConnected = false
    @Published private(set) var lastFailure: String?
    @Published private(set) var checkingConnection = false
    @Published private(set) var testingPipeline = false
    @Published private(set) var processingSeconds: TimeInterval = 0
    @Published private(set) var timingSummary = ""
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
    private var cleanupTask: Task<String, Error>?
    private var skipCleanup = false
    private var sender: Task<Void, Error>?
    private var liveSession: GeminiLiveTranscriber?
    private var timer: Timer?
    private var target: TextInserter.Target?
    private var targetCaptureFailure: String?
    private var shortcutGesture = DictationShortcutGesture()
    private var stopWhenReady = false
    private var sessionKey = ""
    private var sessionOptions = DictationOptions()
    private var sessionRestore = true
    private var generation = UUID()

    init(settings: SettingsStore) {
        self.settings = settings
        refreshPermissions()
        hotKey.onPress = { [weak self] timestamp in self?.shortcutPressed(at: timestamp) }
        hotKey.onRelease = { [weak self] timestamp in self?.shortcutReleased(at: timestamp) }
        hotKey.onUncertainRelease = { [weak self] in
            guard let self, !self.checkingConnection, !self.testingPipeline,
                  self.phase == .preparing || self.phase == .recording else { return }
            self.cancel()
            self.message = "已偵測到快捷鍵放開，但系統延遲使按壓時長不明；已停止錄音，請重新按鍵。"
        }
        registerShortcut()
    }

    var busy: Bool { phase != .idle }
    var statusTitle: String {
        switch phase {
        case .idle: return "隨時開口，文字就位。"
        case .preparing: return checkingConnection ? "正在測試 Gemini 連線…" : "正在準備麥克風…"
        case .recording: return liveConnected ? "正在即時辨識…" : "正在連線辨識服務…"
        case .transcribing: return String(format: "正在完成語音辨識… %.1f 秒", processingSeconds)
        case .polishing: return String(format: "正在整理文字… %.1f 秒", processingSeconds)
        case .inserting: return "正在插入文字…"
        case .testing: return testingPipeline ? "正在測試辨識流程（不錄音）…" : "準備測試文字插入…"
        }
    }
    func registerShortcut() {
        do { try hotKey.register(choice: settings.hotKey); hotKeyError = nil }
        catch { hotKeyError = error.localizedDescription }
    }
    func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        if accessibilityGranted { inserter.prepareCurrentApplication() }
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
        do {
            let key = try GeminiAPIKey.validate(value)
            try KeychainStore.save(key); hasAPIKey = true
            message = "API key 已儲存到 macOS Keychain。"; return true
        }
        catch { message = error.localizedDescription; return false }
    }
    func deleteKey() {
        guard !busy else { return }
        do { try KeychainStore.delete(); hasAPIKey = false; message = "API key 已刪除。" }
        catch { message = error.localizedDescription }
    }
    private func shortcutPressed(at timestamp: TimeInterval) {
        applyShortcut(shortcutGesture.press(at: timestamp, phase: shortcutPhase))
    }
    private func shortcutReleased(at timestamp: TimeInterval) {
        applyShortcut(shortcutGesture.release(at: timestamp, phase: shortcutPhase))
    }
    private var shortcutPhase: DictationShortcutGesture.Phase {
        if checkingConnection || testingPipeline { return .busy }
        switch phase {
        case .idle: return .idle
        case .preparing: return .preparing
        case .recording: return .recording
        default: return .busy
        }
    }
    private func applyShortcut(_ action: DictationShortcutGesture.Action) {
        switch action {
        case .start: startRecording()
        case .finish: finishRecording()
        case .finishWhenReady: stopWhenReady = true
        case .none: break
        }
    }
    /// Authenticates a Live session without opening the microphone or sending user audio.
    func checkConnection() {
        guard !busy else { return }
        lastFailure = nil; liveText = ""
        guard settings.cloudConsent else {
            reset(message: "請先同意使用 Google Gemini，再檢查連線。", isError: true); return
        }
        do {
            guard let key = try KeychainStore.load() else {
                reset(message: "請先在設定儲存自己的 Gemini API key。", isError: true); return
            }
            try GeminiLiveTranscriber.validateConfiguration(apiKey: key, model: settings.asrModel)
            let client = GeminiLiveTranscriber(apiKey: key, model: settings.asrModel)
            let token = UUID(); generation = token
            liveSession = client; checkingConnection = true; phase = .preparing
            message = "只檢查金鑰與 Live 模型連線，不啟動麥克風、不傳送錄音或自訂詞彙。"
            operation = Task { [weak self] in
                do {
                    try await client.start()
                    await client.cancel()
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.reset(message: "Gemini Live 連線成功。可以使用 ⌥ Space 開始錄音；這次檢查未啟動麥克風。")
                } catch {
                    await client.cancel()
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.reset(message: error.localizedDescription, isError: true)
                }
            }
        } catch { reset(message: error.localizedDescription, isError: true) }
    }
    func startRecording() {
        guard phase == .idle else { return }
        lastFailure = nil
        liveText = ""
        liveConnected = false
        timingSummary = ""
        guard settings.cloudConsent else {
            reset(message: "請先在設定同意將你主動錄製的音訊傳送到 Google Gemini。", isError: true); return
        }
        let vocabulary = settings.vocabulary.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        do {
            guard let key = try KeychainStore.load(), !key.isEmpty else {
                reset(message: "請先在設定儲存自己的 Gemini API key。", isError: true); return
            }
            // Validate locally before opening the microphone. A format error must not
            // look like a microphone permission that briefly works and disappears.
            try GeminiLiveTranscriber.validateConfiguration(apiKey: key, model: settings.asrModel,
                                                             languageCodes: [], vocabulary: vocabulary)
            sessionKey = try GeminiAPIKey.validate(key)
        } catch { reset(message: error.localizedDescription, isError: true); return }
        targetCaptureFailure = nil
        do { target = try inserter.captureTarget() }
        catch {
            target = nil
            targetCaptureFailure = error.localizedDescription
            accessibilityGranted = AXIsProcessTrusted()
        }
        sessionOptions = settings.options
        sessionRestore = settings.restoreClipboard
        stopWhenReady = false
        phase = .preparing
        let token = UUID(); generation = token
        liveText = ""
        let client = GeminiLiveTranscriber(apiKey: sessionKey, model: settings.asrModel,
            languageCodes: [], vocabulary: vocabulary,
            onPartial: { [weak self] text in
                Task { @MainActor in
                    guard let self, self.generation == token, self.busy else { return }
                    self.liveText = self.sessionOptions.applyingOrthography(to: text)
                }
            })
        liveSession = client
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await recorder.start()
                guard generation == token, !Task.isCancelled else { return }
                phase = .recording
                message = "麥克風已就緒，正在連線 Gemini。"
                sender = Task { [weak self] in
                    do {
                        try await client.start()
                        if let self, self.generation == token, self.phase == .recording {
                            self.liveConnected = true
                            self.message = self.target == nil ? "\(self.targetCaptureFailure ?? "無法取得輸入位置。") 這次將保留結果供手動複製。" : "音訊正串流至 Google。放開快捷鍵結束；短按可切換錄音。"
                        }
                        for try await chunk in stream {
                            try Task.checkCancellation()
                            try await client.sendAudio(chunk)
                        }
                    } catch {
                        await client.cancel()
                        if let self, self.generation == token, self.phase == .recording {
                            self.recorder.cancel()
                            self.reset(message: error.localizedDescription, isError: !(error is CancellationError))
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
                reset(message: error.localizedDescription, isError: !(error is CancellationError))
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
        beginProcessing(.transcribing)
        message = "正在等待 Live ASR 的最後片段。"
        let key = sessionKey; sessionKey = ""
        let options = sessionOptions
        let capturedTarget = target
        let captureFailure = targetCaptureFailure
        let restore = sessionRestore
        let token = generation
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let asrStarted = ProcessInfo.processInfo.systemUptime
                // Drain every recorded chunk before sending the end-of-activity marker.
                try await sending.value
                let raw = options.applyingOrthography(to: try await client.finish())
                try Task.checkCancellation()
                guard generation == token else { return }
                lastText = raw
                liveText = ""
                timingSummary = String(format: "ASR 收尾 %.2f 秒", ProcessInfo.processInfo.systemUptime - asrStarted)
                var text = raw
                var fallback = ""
                if options.mode == .polished {
                    beginProcessing(.polishing)
                    message = "逐字稿已完成，正在輕度整理；最多等待 8 秒，也可以略過後修。"
                    skipCleanup = false
                    let polishStarted = ProcessInfo.processInfo.systemUptime
                    let polishing = Task { try await GeminiClient().polish(transcript: raw, apiKey: key, options: options) }
                    cleanupTask = polishing
                    do {
                        let polished = try await polishing.value
                        try Task.checkCancellation()
                        guard generation == token else { return }
                        if skipCleanup {
                            text = raw
                            fallback = "已略過後修，使用原始辨識結果。"
                        } else { text = options.applyingOrthography(to: polished) }
                    }
                    catch {
                        try Task.checkCancellation()
                        guard generation == token else { return }
                        if skipCleanup { fallback = "已略過後修，使用原始辨識結果。" }
                        else if Self.isTemporaryCleanupError(error) { fallback = "後修暫時無法完成，已使用原始辨識結果。" }
                        else { throw error }
                    }
                    cleanupTask = nil
                    timingSummary += String(format: " · 後修 %.2f 秒", ProcessInfo.processInfo.systemUptime - polishStarted)
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                lastText = text
                guard let capturedTarget else {
                    reset(message: fallback + "辨識完成。\(captureFailure ?? "未取得輸入位置。") 請複製下方結果。", isError: true); return
                }
                phase = .inserting
                let method = try await inserter.insert(text, into: capturedTarget, restoreClipboard: restore)
                guard generation == token else { return }
                reset(message: fallback + method)
            } catch {
                await client.cancel()
                guard generation == token else { return }
                let stage: String
                switch phase {
                case .polishing: stage = "文字整理失敗"
                case .inserting: stage = "文字插入未完成"
                default: stage = "語音辨識未完成"
                }
                reset(message: error is CancellationError ? "已取消。已送出的音訊無法收回。" : "\(stage)：\(error.localizedDescription)", isError: !(error is CancellationError))
            }
        }
    }

    func skipPolishing() {
        guard phase == .polishing, !testingPipeline else { return }
        skipCleanup = true
        cleanupTask?.cancel()
    }

    private static func isTemporaryCleanupError(_ error: Error) -> Bool {
        guard let error = error as? GeminiError else { return false }
        switch error {
        case .timeout, .cleanupTimeout, .networkFailure: return true
        case .httpStatus(let status): return status == 429 || (500...599).contains(status)
        default: return false
        }
    }

    private func beginProcessing(_ next: Phase) {
        timer?.invalidate()
        processingSeconds = 0
        phase = next
        let started = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == next else { return }
                self.processingSeconds = ProcessInfo.processInfo.systemUptime - started
            }
        }
    }

    /// Uses a fixed, locally synthesized sentence to exercise the real provider pipeline.
    /// No microphone, user vocabulary, destination capture, or insertion is involved.
    func testPipeline() {
        guard !busy, settings.cloudConsent else { return }
        lastFailure = nil; liveText = ""; timingSummary = ""
        do {
            guard let key = try KeychainStore.load() else { throw GeminiError.invalidAPIKey }
            let options = DictationOptions(model: settings.options.model, language: settings.options.language,
                                           vocabulary: "", mode: .polished)
            try GeminiLiveTranscriber.validateConfiguration(apiKey: key, model: settings.asrModel)
            let token = UUID(); generation = token
            testingPipeline = true
            beginProcessing(.testing)
            message = "正在本機合成固定測試句；不使用麥克風、不插入文字。"
            let client = GeminiLiveTranscriber(apiKey: key, model: settings.asrModel, onPartial: { [weak self] text in
                Task { @MainActor in
                    guard let self, self.generation == token, self.testingPipeline else { return }
                    self.liveText = options.applyingOrthography(to: text)
                }
            })
            liveSession = client
            operation = Task { [weak self] in
                guard let self else { return }
                do {
                    let speech = DiagnosticSpeech()
                    let pcm = try await speech.render()
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    message = "正在傳送固定測試語音至 Google；麥克風未啟動。"
                    let connectStarted = ProcessInfo.processInfo.systemUptime
                    try await client.start()
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    timingSummary = String(format: "連線 %.2f 秒", ProcessInfo.processInfo.systemUptime - connectStarted)
                    for offset in stride(from: 0, to: pcm.count, by: 3_200) {
                        try Task.checkCancellation()
                        try await client.sendAudio(Data(pcm[offset..<min(offset + 3_200, pcm.count)]))
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    beginProcessing(.transcribing)
                    message = "測試語音已傳送，正在等待 ASR 定稿。"
                    let asrStarted = ProcessInfo.processInfo.systemUptime
                    let raw = options.applyingOrthography(to: try await client.finish())
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    timingSummary += String(format: " · ASR 收尾 %.2f 秒", ProcessInfo.processInfo.systemUptime - asrStarted)
                    let events = await client.diagnostics()
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    timingSummary += "（定稿 \(events.finalSegmentCount)，turnComplete \(events.turnComplete ? "有" : "無")）"
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    lastText = raw; liveText = ""
                    beginProcessing(.polishing)
                    message = "ASR 測試成功，正在量測文字後修。"
                    let polishStarted = ProcessInfo.processInfo.systemUptime
                    let result = try await GeminiClient().polish(transcript: raw, apiKey: key, options: options)
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    timingSummary += String(format: " · 後修 %.2f 秒", ProcessInfo.processInfo.systemUptime - polishStarted)
                    lastText = options.applyingOrthography(to: result)
                    reset(message: "辨識與後修測試成功。\(timingSummary)。沒有錄音或插入文字。")
                } catch {
                    let events = await client.diagnostics()
                    await client.cancel()
                    guard generation == token else { return }
                    reset(message: "測試未完成：\(error.localizedDescription) \(timingSummary)；ASR 定稿 \(events.finalSegmentCount)，暫稿 \(events.interimUpdateCount)，待定暫稿 \(events.hasInterim ? "有" : "無")。", isError: !(error is CancellationError))
                }
            }
        } catch { reset(message: error.localizedDescription, isError: true) }
    }
    func cancel() {
        guard phase != .inserting else { return }
        generation = UUID()
        operation?.cancel(); operation = nil
        cleanupTask?.cancel(); cleanupTask = nil
        sender?.cancel(); sender = nil
        if let client = liveSession { Task { await client.cancel() } }
        recorder.cancel()
        reset(message: "已取消；本機音訊緩衝已釋放，已傳送至 Google 的音訊無法收回。")
    }
    private func reset(message: String, isError: Bool = false) {
        timer?.invalidate(); timer = nil
        sessionKey = ""; target = nil; targetCaptureFailure = nil; stopWhenReady = false; shortcutGesture.reset()
        liveSession = nil; sender = nil
        cleanupTask = nil; skipCleanup = false
        phase = .idle; level = 0
        liveConnected = false
        checkingConnection = false
        testingPipeline = false
        self.message = message
        lastFailure = isError ? message : nil
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
                reset(message: error.localizedDescription, isError: true)
            }
        }
    }
    func shutdown() {
        operation?.cancel(); sender?.cancel(); cleanupTask?.cancel()
        if let client = liveSession { Task { await client.cancel() } }
        recorder.cancel(); timer?.invalidate(); hotKey.unregister()
    }
}
