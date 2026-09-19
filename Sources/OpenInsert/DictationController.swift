import AppKit
import ApplicationServices
import AVFoundation
import Combine
import OpenInsertCore

@MainActor final class DictationController: ObservableObject {
    enum Phase { case idle, preparing, recording, transcribing, polishing, inserting, testing }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var message = ""
    @Published var lastText = ""
    @Published private(set) var liveText = ""
    @Published private(set) var liveConnected = false
    @Published private(set) var lastFailure: String?
    @Published private(set) var failureRevision: UInt64 = 0
    @Published private(set) var copiedToClipboard = false
    @Published private(set) var pasteDispatched = false
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
    @Published private(set) var recordingShortcut = false
    @Published private(set) var shortcutCaptureError: String?
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
    private var targetCaptureFailure: LocalizedMessage?
    private var shortcutGesture = DictationShortcutGesture()
    private var stopWhenReady = false
    private var sessionKey = ""
    private var sessionOptions = DictationOptions()
    private var sessionRestore = true
    private var generation = UUID()
    private var localizationSubscription: AnyCancellable?
    private var messageDescriptor = LocalizedMessage("initial")
    private var failureDescriptor: LocalizedMessage?
    private var timingDescriptors: [LocalizedMessage] = []
    private var registrationFailure: Error?
    private var captureShortcutFailure: Error?

    private func setMessage(_ value: LocalizedMessage) {
        messageDescriptor = value
        message = value.render(using: settings.localizer)
    }
    private func setFailure(_ value: LocalizedMessage?) {
        failureDescriptor = value
        lastFailure = value?.render(using: settings.localizer)
        if value != nil { failureRevision &+= 1 }
    }
    private func setTiming(_ value: LocalizedMessage?) {
        timingDescriptors = value.map { [$0] } ?? []
        timingSummary = timingMessage.render(using: settings.localizer)
    }
    private func appendTiming(_ value: LocalizedMessage) {
        timingDescriptors.append(value)
        timingSummary = timingMessage.render(using: settings.localizer)
    }
    private var timingMessage: LocalizedMessage { .joined(timingDescriptors, separator: " · ") }
    private func refreshLocalization(_ language: InterfaceLanguage) {
        let localizer = AppLocalizer(language: language)
        message = messageDescriptor.render(using: localizer)
        lastFailure = failureDescriptor?.render(using: localizer)
        timingSummary = timingMessage.render(using: localizer)
        hotKeyError = registrationFailure.map { LocalizedMessage.error($0).render(using: localizer) }
        shortcutCaptureError = captureShortcutFailure.map { LocalizedMessage.error($0).render(using: localizer) }
    }
    private func setHotKeyError(_ error: Error?) {
        registrationFailure = error
        hotKeyError = error.map { LocalizedMessage.error($0).render(using: settings.localizer) }
    }
    private func setShortcutCaptureError(_ error: Error?) {
        captureShortcutFailure = error
        shortcutCaptureError = error.map { LocalizedMessage.error($0).render(using: settings.localizer) }
    }

    init(settings: SettingsStore) {
        self.settings = settings
        localizationSubscription = settings.$interfaceLanguage.removeDuplicates().sink { [weak self] language in
            self?.refreshLocalization(language)
        }
        refreshPermissions()
        hotKey.onPress = { [weak self] timestamp in self?.shortcutPressed(at: timestamp) }
        hotKey.onRelease = { [weak self] timestamp in self?.shortcutReleased(at: timestamp) }
        hotKey.onUncertainRelease = { [weak self] in
            guard let self, !self.checkingConnection, !self.testingPipeline,
                  self.phase == .preparing || self.phase == .recording else { return }
            self.cancel()
            self.setMessage(LocalizedMessage("shortcut.uncertain"))
        }
        registerShortcut()
    }

    var busy: Bool { phase != .idle }
    var statusTitle: String {
        let key: String
        switch phase {
        case .idle: key = copiedToClipboard ? "status.copied" : "status.idle"
        case .preparing: key = checkingConnection ? "status.connection" : "status.preparing"
        case .recording: key = liveConnected ? "status.recording" : "status.connecting"
        case .transcribing: key = "status.transcribing"
        case .polishing: key = "status.polishing"
        case .inserting: key = "status.inserting"
        case .testing: key = testingPipeline ? "status.pipeline" : "status.testInsertion"
        }
        return settings.localizer.text(key, table: "Status", arguments: [processingSeconds])
    }
    func registerShortcut() {
        guard !recordingShortcut else { return }
        do { try hotKey.register(shortcut: settings.hotKey); setHotKeyError(nil) }
        catch { setHotKeyError(error) }
    }
    @discardableResult func beginShortcutRecording() -> Bool {
        guard !busy, !recordingShortcut else { return false }
        // Temporarily release the current combination so it can be recorded
        // locally without starting the microphone. Cancel restores it unchanged.
        hotKey.unregister()
        shortcutGesture.reset()
        setShortcutCaptureError(nil)
        recordingShortcut = true
        return true
    }
    @discardableResult func saveShortcut(_ candidate: KeyboardShortcut) -> Bool {
        guard recordingShortcut, !busy else { return false }
        do {
            try hotKey.register(shortcut: candidate)
            settings.hotKey = candidate
            setHotKeyError(nil)
            setShortcutCaptureError(nil)
            recordingShortcut = false
            return true
        } catch {
            setShortcutCaptureError(error)
            return false
        }
    }
    func cancelShortcutRecording() {
        guard recordingShortcut else { return }
        recordingShortcut = false
        setShortcutCaptureError(nil)
        registerShortcut()
    }
    func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        if accessibilityGranted { inserter.prepareCurrentApplication() }
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        do { hasAPIKey = !(try KeychainStore.load() ?? "").isEmpty }
        catch { hasAPIKey = false; setMessage(.error(error)) }
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
            setMessage(LocalizedMessage("key.saved")); return true
        }
        catch { setMessage(.error(error)); return false }
    }
    func deleteKey() {
        guard !busy else { return }
        do { try KeychainStore.delete(); hasAPIKey = false; setMessage(LocalizedMessage("key.deleted")) }
        catch { setMessage(.error(error)) }
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
        guard !recordingShortcut else { return }
        switch action {
        case .start: startRecording()
        case .finish: finishRecording()
        case .finishWhenReady: stopWhenReady = true
        case .none: break
        }
    }
    /// Authenticates a Live session without opening the microphone or sending user audio.
    func checkConnection() {
        guard !busy, !recordingShortcut else { return }
        setFailure(nil); liveText = ""
        guard settings.cloudConsent else {
            reset(message: LocalizedMessage("connection.consent"), isError: true); return
        }
        do {
            guard let key = try KeychainStore.load() else {
                reset(message: LocalizedMessage("key.required"), isError: true); return
            }
            try GeminiLiveTranscriber.validateConfiguration(apiKey: key, model: settings.asrModel)
            let client = GeminiLiveTranscriber(apiKey: key, model: settings.asrModel)
            let token = UUID(); generation = token
            liveSession = client; checkingConnection = true; phase = .preparing
            setMessage(LocalizedMessage("connection.check"))
            operation = Task { [weak self] in
                do {
                    try await client.start()
                    await client.cancel()
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.reset(message: LocalizedMessage("connection.success", [self.settings.hotKey.displayName]))
                } catch {
                    await client.cancel()
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.reset(message: .error(error), isError: true)
                }
            }
        } catch { reset(message: .error(error), isError: true) }
    }
    func startRecording() {
        guard phase == .idle, !recordingShortcut else { return }
        setFailure(nil)
        copiedToClipboard = false
        pasteDispatched = false
        liveText = ""
        liveConnected = false
        setTiming(nil)
        guard settings.cloudConsent else {
            reset(message: LocalizedMessage("recording.consent"), isError: true); return
        }
        let vocabulary = settings.vocabulary.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        do {
            guard let key = try KeychainStore.load(), !key.isEmpty else {
                reset(message: LocalizedMessage("key.required"), isError: true); return
            }
            // Validate locally before opening the microphone. A format error must not
            // look like a microphone permission that briefly works and disappears.
            try GeminiLiveTranscriber.validateConfiguration(apiKey: key, model: settings.asrModel,
                                                             languageCodes: [], vocabulary: vocabulary)
            sessionKey = try GeminiAPIKey.validate(key)
        } catch { reset(message: .error(error), isError: true); return }
        targetCaptureFailure = nil
        do { target = try inserter.captureTarget() }
        catch {
            target = nil
            targetCaptureFailure = captureFailureDescription(error)
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
                setMessage(LocalizedMessage("recording.ready"))
                sender = Task { [weak self] in
                    do {
                        try await client.start()
                        if let self, self.generation == token, self.phase == .recording {
                            self.liveConnected = true
                            self.setMessage(self.target == nil ? LocalizedMessage("recording.noTarget", values: [self.targetCaptureFailure ?? .literal("")]) : LocalizedMessage("recording.streaming"))
                        }
                        for try await chunk in stream {
                            try Task.checkCancellation()
                            try await client.sendAudio(chunk)
                        }
                    } catch {
                        await client.cancel()
                        if let self, self.generation == token, self.phase == .recording {
                            self.recorder.cancel()
                            self.reset(message: .error(error), isError: !(error is CancellationError))
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
                reset(message: .error(error), isError: !(error is CancellationError))
            }
        }
    }
    func finishRecording() {
        guard phase == .recording else { return }
        timer?.invalidate(); timer = nil
        guard let client = liveSession, let sending = sender else { cancel(); return }
        let duration = recorder.duration
        recorder.stop()
        guard duration >= 0.35 else { cancel(); setMessage(LocalizedMessage("recording.short")); return }
        beginProcessing(.transcribing)
        setMessage(LocalizedMessage("recording.finalizing"))
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
                setTiming(LocalizedMessage("timing.asr", [ProcessInfo.processInfo.systemUptime - asrStarted]))
                var text = raw
                var fallback = LocalizedMessage.literal("")
                if options.mode == .polished {
                    beginProcessing(.polishing)
                    setMessage(LocalizedMessage("cleanup.progress"))
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
                            fallback = LocalizedMessage("cleanup.skipped")
                        } else { text = options.applyingOrthography(to: polished) }
                    }
                    catch {
                        try Task.checkCancellation()
                        guard generation == token else { return }
                        if skipCleanup { fallback = LocalizedMessage("cleanup.skipped") }
                        else if Self.isTemporaryCleanupError(error) { fallback = LocalizedMessage("cleanup.fallback") }
                        else { throw error }
                    }
                    cleanupTask = nil
                    appendTiming(LocalizedMessage("timing.cleanup", [ProcessInfo.processInfo.systemUptime - polishStarted]))
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                lastText = text
                try await deliverFinalText(text, to: capturedTarget, unavailableReason: captureFailure,
                                           prefix: fallback, restoreClipboard: restore, token: token)
            } catch {
                await client.cancel()
                guard generation == token else { return }
                let stage: LocalizedMessage
                switch phase {
                case .polishing: stage = LocalizedMessage("stage.polishing")
                case .inserting: stage = LocalizedMessage("stage.inserting")
                default: stage = LocalizedMessage("stage.transcribing")
                }
                reset(message: error is CancellationError ? LocalizedMessage("error.cancelled") : LocalizedMessage("stage.failure", values: [stage, .error(error)]), isError: !(error is CancellationError))
            }
        }
    }

    /// Called only after a finalized, accepted result (or the fixed insertion test).
    /// Unknown failures and clipboard ownership failures must not trigger another write.
    private func deliverFinalText(_ text: String, to captured: TextInserter.Target?,
                                  unavailableReason: LocalizedMessage?, prefix: LocalizedMessage = .literal(""),
                                  restoreClipboard: Bool, token: UUID) async throws {
        try Task.checkCancellation()
        guard generation == token else { return }
        phase = .inserting
        var copyReason = unavailableReason ?? LocalizedMessage("insert.noTarget")
        if let captured {
            do {
                let method = try await inserter.insert(text, into: captured, restoreClipboard: restoreClipboard) { [weak self] in
                    guard let self, self.generation == token, self.phase == .inserting else { return }
                    self.pasteDispatched = true
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                reset(message: .joined([prefix, method], separator: " "))
                return
            } catch {
                try Task.checkCancellation()
                guard generation == token else { return }
                // TextInserter throws these errors before sending the paste.
                // Once a paste is sent it never throws or retries delivery.
                guard let insertionError = error as? TextInserter.InsertionError else { throw error }
                switch insertionError {
                case .emptyText, .clipboardChanged, .clipboardUnreadable, .clipboardWriteFailed:
                    throw error
                case .accessibilityDenied, .noInputField, .secureField, .targetChanged,
                     .selectionChanged, .modifierHeld, .eventCreationFailed, .terminalControlText,
                     .accessibilityPreparing, .unsupportedInputRole, .accessibilityReadFailed,
                     .invalidAccessibilityValue:
                    copyReason = .error(insertionError)
                }
            }
        }
        try Task.checkCancellation()
        guard generation == token else { return }
        do {
            try inserter.copyToClipboard(text)
            reset(message: LocalizedMessage("insert.copied", values: [prefix, copyReason]), copied: true)
        } catch {
            reset(message: LocalizedMessage("insert.copyFailed", values: [.error(error)]), isError: true)
        }
    }

    private func captureFailureDescription(_ error: Error) -> LocalizedMessage {
        guard let diagnostic = inserter.lastPreparationDiagnostic else { return .error(error) }
        return LocalizedMessage("insert.captureFailure", values: [.error(error), diagnostic])
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
        guard !busy, !recordingShortcut, settings.cloudConsent else { return }
        setFailure(nil); liveText = ""; setTiming(nil)
        do {
            guard let key = try KeychainStore.load() else { throw GeminiError.invalidAPIKey }
            let options = DictationOptions(model: settings.options.model, language: settings.options.language,
                                           vocabulary: "", mode: .polished)
            try GeminiLiveTranscriber.validateConfiguration(apiKey: key, model: settings.asrModel)
            let token = UUID(); generation = token
            testingPipeline = true
            beginProcessing(.testing)
            setMessage(LocalizedMessage("pipeline.synthesizing"))
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
                    setMessage(LocalizedMessage("pipeline.sending"))
                    let connectStarted = ProcessInfo.processInfo.systemUptime
                    try await client.start()
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    setTiming(LocalizedMessage("timing.connection", [ProcessInfo.processInfo.systemUptime - connectStarted]))
                    for offset in stride(from: 0, to: pcm.count, by: 3_200) {
                        try Task.checkCancellation()
                        try await client.sendAudio(Data(pcm[offset..<min(offset + 3_200, pcm.count)]))
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    beginProcessing(.transcribing)
                    setMessage(LocalizedMessage("pipeline.finalizing"))
                    let asrStarted = ProcessInfo.processInfo.systemUptime
                    let raw = options.applyingOrthography(to: try await client.finish())
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    appendTiming(LocalizedMessage("timing.asr", [ProcessInfo.processInfo.systemUptime - asrStarted]))
                    let events = await client.diagnostics()
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    appendTiming(LocalizedMessage("timing.events", values: [.literal(String(events.finalSegmentCount)), LocalizedMessage(events.turnComplete ? "yes" : "no")]))
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    lastText = raw; liveText = ""
                    beginProcessing(.polishing)
                    setMessage(LocalizedMessage("pipeline.polishing"))
                    let polishStarted = ProcessInfo.processInfo.systemUptime
                    let result = try await GeminiClient().polish(transcript: raw, apiKey: key, options: options)
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    appendTiming(LocalizedMessage("timing.cleanup", [ProcessInfo.processInfo.systemUptime - polishStarted]))
                    lastText = options.applyingOrthography(to: result)
                    reset(message: LocalizedMessage("pipeline.success", values: [timingMessage]))
                } catch {
                    let events = await client.diagnostics()
                    await client.cancel()
                    guard generation == token else { return }
                    reset(message: LocalizedMessage("pipeline.failed", values: [.error(error), timingMessage, .literal(String(events.finalSegmentCount)), .literal(String(events.interimUpdateCount)), LocalizedMessage(events.hasInterim ? "yes" : "no")]), isError: !(error is CancellationError))
                }
            }
        } catch { reset(message: .error(error), isError: true) }
    }
    func cancel() {
        guard phase != .inserting else { return }
        generation = UUID()
        operation?.cancel(); operation = nil
        cleanupTask?.cancel(); cleanupTask = nil
        sender?.cancel(); sender = nil
        if let client = liveSession { Task { await client.cancel() } }
        recorder.cancel()
        reset(message: LocalizedMessage("operation.cancelled"))
    }
    private func reset(message: LocalizedMessage, isError: Bool = false, copied: Bool = false) {
        timer?.invalidate(); timer = nil
        sessionKey = ""; target = nil; targetCaptureFailure = nil; stopWhenReady = false; shortcutGesture.reset()
        liveSession = nil; sender = nil
        cleanupTask = nil; skipCleanup = false
        phase = .idle; level = 0
        liveConnected = false
        checkingConnection = false
        testingPipeline = false
        setMessage(message)
        copiedToClipboard = copied
        pasteDispatched = false
        setFailure(isError ? message : nil)
    }
    func copyResult() {
        guard !lastText.isEmpty else { return }
        do {
            try inserter.copyToClipboard(lastText)
            setMessage(LocalizedMessage("result.copied"))
            copiedToClipboard = true
            setFailure(nil)
        } catch { setMessage(.error(error)); setFailure(.error(error)) }
    }
    func clearResult() { lastText = ""; copiedToClipboard = false; setMessage(LocalizedMessage("result.cleared")) }
    func testInsertion() {
        guard !busy, !recordingShortcut else { return }
        phase = .testing
        copiedToClipboard = false; setFailure(nil)
        pasteDispatched = false
        let token = UUID(); generation = token
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                for second in (1...5).reversed() {
                    setMessage(LocalizedMessage("insert.countdown", [second]))
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                let test = LocalizedMessage("insert.fixedSentence").render(using: settings.localizer)
                lastText = test
                let captured: TextInserter.Target?
                let reason: LocalizedMessage?
                do { captured = try inserter.captureTarget(); reason = nil }
                catch { captured = nil; reason = captureFailureDescription(error) }
                try await deliverFinalText(test, to: captured, unavailableReason: reason,
                                           restoreClipboard: settings.restoreClipboard, token: token)
            } catch {
                guard generation == token else { return }
                reset(message: .error(error), isError: true)
            }
        }
    }
    func shutdown() {
        operation?.cancel(); sender?.cancel(); cleanupTask?.cancel()
        if let client = liveSession { Task { await client.cancel() } }
        recorder.cancel(); timer?.invalidate(); hotKey.unregister()
    }
}
