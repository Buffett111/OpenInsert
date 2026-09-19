import Foundation

/// One push-to-talk Live API session. PCM must be mono, signed 16-bit little-endian, 16 kHz.
///
/// `inputTranscription` contains committed segments; `interimInputTranscription` replaces a
/// speculative preview. Google's wire documentation does not guarantee input transcription
/// ordering relative to `turnComplete`. Finalization therefore uses an explicitly bounded
/// heuristic: after activityEnd, require turnComplete and 1 second with no transcription
/// updates, with no unresolved interim text. A 20-second deadline fails closed.
/// See https://ai.google.dev/gemini-api/docs/live-api/live-transcribe and /api/live.
public actor GeminiLiveTranscriber {
    private enum Phase { case idle, starting, streaming, finishing, complete, failed, cancelled }
    private let apiKey: String
    private let model: String
    private let languageCodes: [String]
    private let vocabulary: [String]
    private let onPartial: @Sendable (String) -> Void
    private let transport: any GeminiLiveTransport
    private let timing: GeminiLiveTiming
    private let clock: any GeminiLiveClock
    private var phase = Phase.idle
    private var failure: Error?
    private var transcript = GeminiLiveTranscript()
    private var result: String?
    private var sentAudioBytes = 0
    private var endDispatched = false
    private var turnComplete = false
    private var revision: UInt64 = 0
    private var deadlineRevision: UInt64 = 0
    private var activeWrite: UUID?
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var finishWaiter: CheckedContinuation<String, Error>?
    private var receiver: Task<Void, Never>?
    private var starter: Task<Void, Never>?
    private var finalizer: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var drain: Task<Void, Never>?
    private var sendTail: Task<Void, Error>?

    public init(
        apiKey: String,
        model: String = "gemini-3.5-transcribe-live",
        languageCodes: [String] = [],
        vocabulary: [String] = [],
        onPartial: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.apiKey = apiKey
        self.model = model
        self.languageCodes = languageCodes
        self.vocabulary = vocabulary
        self.onPartial = onPartial
        self.transport = GeminiNativeLiveTransport()
        self.timing = GeminiLiveTiming()
        self.clock = GeminiLiveSystemClock()
    }

    /// Internal transport injection exercises the same state machine without credentials/network.
    init(
        apiKey: String,
        model: String = "gemini-3.5-transcribe-live",
        languageCodes: [String] = [],
        vocabulary: [String] = [],
        transport: any GeminiLiveTransport,
        timing: GeminiLiveTiming = GeminiLiveTiming(),
        clock: any GeminiLiveClock = GeminiLiveSystemClock(),
        onPartial: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.apiKey = apiKey
        self.model = model
        self.languageCodes = languageCodes
        self.vocabulary = vocabulary
        self.onPartial = onPartial
        self.transport = transport
        self.timing = timing
        self.clock = clock
    }

    public func start() async throws {
        try Task.checkCancellation()
        guard phase == .idle else { throw failure ?? GeminiLiveError.invalidState }
        let request = try GeminiLiveProtocol.request(apiKey: apiKey)
        let setup = try GeminiLiveProtocol.setup(model: model, languageCodes: languageCodes, vocabulary: vocabulary)
        phase = .starting
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startWaiter = continuation
                installDeadline(after: timing.setup, error: .setupTimeout)
                starter = Task { [weak self, transport] in
                    do {
                        try Task.checkCancellation()
                        try transport.connect(request: request)
                        await self?.beginReceiving()
                        try await self?.enqueue(setup)
                    } catch {
                        await self?.fail(Self.redacted(error))
                    }
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    /// Validates locally before the caller opens the microphone. This does not make a
    /// network request or confirm Google model access, quota, or credential validity.
    public nonisolated static func validateConfiguration(
        apiKey: String,
        model: String = "gemini-3.5-transcribe-live",
        languageCodes: [String] = [],
        vocabulary: [String] = []
    ) throws {
        _ = try GeminiLiveProtocol.request(apiKey: apiKey)
        _ = try GeminiLiveProtocol.setup(model: model, languageCodes: languageCodes, vocabulary: vocabulary)
    }

    /// Call sequentially from the microphone stream; sending also permits incoming previews.
    public func sendAudio(_ data: Data) async throws {
        try Task.checkCancellation()
        guard phase == .streaming else { throw failure ?? GeminiLiveError.invalidState }
        guard !data.isEmpty, data.count.isMultiple(of: 2), data.count <= 32_000 else {
            throw GeminiLiveError.invalidAudio
        }
        guard sentAudioBytes <= 3_840_000 - data.count else {
            fail(GeminiLiveError.audioTooLong)
            throw GeminiLiveError.audioTooLong
        }
        sentAudioBytes += data.count
        let message = try GeminiLiveProtocol.audio(data)
        try await withTaskCancellationHandler {
            do {
                try await enqueue(message)
                try Task.checkCancellation()
                if let failure { throw failure }
            } catch {
                let safe = Self.redacted(error)
                fail(safe)
                throw failure ?? safe
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    /// Flush queued audio, signal activityEnd, then wait for the bounded finalization policy.
    public func finish() async throws -> String {
        try Task.checkCancellation()
        if let result, phase == .complete { return result }
        guard phase == .streaming else { throw failure ?? GeminiLiveError.invalidState }
        phase = .finishing
        turnComplete = false
        return try await withTaskCancellationHandler {
            let final = try await withCheckedThrowingContinuation { continuation in
                finishWaiter = continuation
                installDeadline(after: timing.finalization, error: .finalizationTimeout)
                finalizer = Task { [weak self] in
                    do {
                        try await self?.enqueue(GeminiLiveProtocol.activityEnd, marksEnd: true)
                    } catch {
                        await self?.fail(Self.redacted(error))
                    }
                }
            }
            try Task.checkCancellation()
            return final
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    public func cancel() async {
        guard phase != .complete && phase != .cancelled else { return }
        phase = .cancelled
        failure = CancellationError()
        releaseWaiters(throwing: CancellationError())
        close()
    }

    private func enqueue(_ message: String, marksEnd: Bool = false) async throws {
        let previous = sendTail
        let sendTimeout = timing.send
        let next = Task { [weak self, transport, clock] in
            if let previous { try await previous.value }
            try Task.checkCancellation()
            let writeID = UUID()
            await self?.beginWrite(writeID)
            // A stalled write must not prevent the microphone drain from reaching finish().
            let watchdog = Task { [weak self] in
                guard await clock.sleep(for: sendTimeout) else { return }
                await self?.writeTimedOut(writeID)
            }
            do {
                if marksEnd { await self?.markEndDispatched() }
                try await transport.send(message)
                await self?.endWrite(writeID)
                watchdog.cancel()
            } catch {
                await self?.endWrite(writeID)
                watchdog.cancel()
                throw error
            }
        }
        sendTail = next
        try await next.value
    }

    private func markEndDispatched() { endDispatched = true }

    private func beginWrite(_ id: UUID) { activeWrite = id }
    private func endWrite(_ id: UUID) { if activeWrite == id { activeWrite = nil } }
    private func writeTimedOut(_ id: UUID) {
        guard activeWrite == id else { return }
        fail(GeminiLiveError.network)
    }

    private func beginReceiving() {
        guard phase == .starting else { return }
        receiver = Task { [weak self, transport] in
            do {
                while !Task.isCancelled {
                    let data = try await transport.receive()
                    try Task.checkCancellation()
                    let event = try GeminiLiveEvent.decode(data)
                    await self?.accept(event)
                }
            } catch {
                await self?.fail(Self.redacted(error))
            }
        }
    }

    private func accept(_ event: GeminiLiveEvent) {
        guard phase == .starting || phase == .streaming || phase == .finishing else { return }
        if event.rejected { fail(GeminiLiveError.serverRejected); return }
        if event.interrupted { fail(GeminiLiveError.interrupted); return }
        if event.goAway { fail(GeminiLiveError.network); return }
        if event.setupComplete {
            guard phase == .starting else { fail(GeminiLiveError.invalidResponse); return }
            // An activityStart is sent only after the documented setupComplete barrier.
            starter = Task { [weak self] in
                do {
                    try await self?.enqueue(GeminiLiveProtocol.activityStart)
                    await self?.ready()
                } catch {
                    await self?.fail(Self.redacted(error))
                }
            }
            return
        }
        guard phase == .streaming || phase == .finishing else {
            // Usage-only messages are harmless during setup; speech before setup is invalid.
            if event.finalText != nil || event.interimText != nil || event.turnComplete {
                fail(GeminiLiveError.invalidResponse)
            }
            return
        }
        do {
            let changed = try transcript.consume(event)
            if changed { onPartial(transcript.preview) }
            if phase == .finishing && endDispatched {
                if event.turnComplete { turnComplete = true }
                if event.finalText != nil || event.interimText != nil || event.turnComplete {
                    revision &+= 1
                    scheduleDrain()
                }
            }
        } catch {
            fail(Self.redacted(error))
        }
    }

    private func ready() {
        guard phase == .starting else { return }
        phase = .streaming
        cancelDeadline()
        let waiter = startWaiter
        startWaiter = nil
        waiter?.resume()
    }

    private func installDeadline(after seconds: TimeInterval, error: GeminiLiveError) {
        cancelDeadline()
        let expectedRevision = deadlineRevision
        deadline = Task { [weak self, clock] in
            guard await clock.sleep(for: seconds) else { return }
            await self?.deadlineExpired(revision: expectedRevision, error: error)
        }
    }

    private func cancelDeadline() {
        // Cancellation alone cannot retract a timer callback already queued on the actor.
        deadlineRevision &+= 1
        deadline?.cancel()
        deadline = nil
    }

    private func deadlineExpired(revision expected: UInt64, error: GeminiLiveError) {
        guard deadlineRevision == expected else { return }
        fail(error)
    }

    private func scheduleDrain() {
        drain?.cancel()
        guard turnComplete, !transcript.hasInterim else { return }
        let expectedRevision = revision
        let interval = timing.quietDrain
        drain = Task { [weak self, clock] in
            guard await clock.sleep(for: interval) else { return }
            await self?.completeIfQuiet(revision: expectedRevision)
        }
    }

    private func completeIfQuiet(revision expected: UInt64) {
        guard phase == .finishing, endDispatched, turnComplete, revision == expected, !transcript.hasInterim else { return }
        let text = transcript.committed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { fail(GeminiLiveError.emptyTranscript); return }
        result = text
        phase = .complete
        let waiter = finishWaiter
        finishWaiter = nil
        close()
        waiter?.resume(returning: text)
    }

    private func fail(_ error: Error) {
        guard phase != .complete && phase != .failed && phase != .cancelled else { return }
        phase = .failed
        failure = error
        releaseWaiters(throwing: error)
        close()
    }

    private func releaseWaiters(throwing error: Error) {
        let start = startWaiter
        let finish = finishWaiter
        startWaiter = nil
        finishWaiter = nil
        start?.resume(throwing: error)
        finish?.resume(throwing: error)
    }

    private func close() {
        cancelDeadline()
        activeWrite = nil
        drain?.cancel(); drain = nil
        starter?.cancel(); starter = nil
        finalizer?.cancel(); finalizer = nil
        receiver?.cancel(); receiver = nil
        sendTail?.cancel(); sendTail = nil
        transport.cancel()
    }

    private nonisolated static func redacted(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let known = error as? GeminiLiveError { return known }
        if (error as? URLError)?.code == .cancelled { return CancellationError() }
        return GeminiLiveError.network
    }
}

public enum GeminiLiveError: Error, LocalizedError, Equatable {
    case invalidConfiguration, invalidState, invalidAudio, audioTooLong
    case invalidAPIKey(GeminiAPIKeyValidationError), invalidModel, invalidLanguageCodes, invalidVocabulary
    case setupTimeout, finalizationTimeout, network, serverRejected, invalidResponse
    case oversizedResponse, emptyTranscript, interrupted

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Check the Gemini API key, Live model, language codes, and vocabulary."
        case .invalidAPIKey(let issue): return issue.errorDescription
        case .invalidModel: return "The Live ASR model ID is invalid. Use gemini-3.5-transcribe-live without a URL or models/ prefix."
        case .invalidLanguageCodes: return "Live language hints must contain at most 16 language codes, such as en-US. Clear invalid language hints."
        case .invalidVocabulary: return "Custom vocabulary must contain at most 1,000 nonempty terms, each at most 512 UTF-8 bytes and 16,000 bytes total. Shorten the vocabulary in Settings."
        case .invalidState: return "The live dictation session is not ready. Start a new recording."
        case .invalidAudio: return "Live audio must contain mono 16-bit PCM samples at 16 kHz."
        case .audioTooLong: return "Live dictation reached the 120-second audio limit."
        case .setupTimeout: return "Gemini Live did not become ready within 10 seconds. Nothing was inserted."
        case .finalizationTimeout: return "Could not confirm the end of the live transcript within 20 seconds. Review the preview; nothing was inserted."
        case .network: return "The Gemini Live connection failed. Review the preview; nothing was inserted."
        case .serverRejected: return "Gemini Live rejected the session. Check the API key and model access. Nothing was inserted."
        case .invalidResponse: return "Gemini Live returned an unexpected response. Nothing was inserted."
        case .oversizedResponse: return "The live transcript exceeded its size limit. Nothing was inserted."
        case .emptyTranscript: return "No intelligible speech was returned. Nothing was inserted."
        case .interrupted: return "Gemini Live interrupted the transcription. Review the preview; nothing was inserted."
        }
    }
}

struct GeminiLiveTiming: Sendable {
    var setup: TimeInterval = 10
    var finalization: TimeInterval = 20
    var quietDrain: TimeInterval = 1
    var send: TimeInterval = 10
}

/// A delay reports cancellation as data, so normal timer replacement never throws from a
/// background task. The state machine also rejects stale callbacks after an expiry/cancel race.
protocol GeminiLiveClock: Sendable {
    func sleep(for seconds: TimeInterval) async -> Bool
}

struct GeminiLiveSystemClock: GeminiLiveClock {
    func sleep(for seconds: TimeInterval) async -> Bool {
        let delay = GeminiLiveDelay()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { delay.start(seconds: seconds, continuation: $0) }
        } onCancel: {
            delay.resolve(false)
        }
    }
}

private final class GeminiLiveDelay: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var work: DispatchWorkItem?

    func start(seconds: TimeInterval, continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(returning: outcome)
            return
        }
        self.continuation = continuation
        let work = DispatchWorkItem { [weak self] in self?.resolve(true) }
        self.work = work
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func resolve(_ value: Bool) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = value
        let waiter = continuation
        continuation = nil
        let scheduled = work
        work = nil
        lock.unlock()
        scheduled?.cancel()
        waiter?.resume(returning: value)
    }
}

enum GeminiLiveProtocol {
    static let endpoint = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
    static let activityStart = "{\"realtimeInput\":{\"activityStart\":{}}}"
    static let activityEnd = "{\"realtimeInput\":{\"activityEnd\":{}}}"

    static func request(apiKey: String) throws -> URLRequest {
        let key: String
        do { key = try GeminiAPIKey.validate(apiKey) }
        catch let issue as GeminiAPIKeyValidationError { throw GeminiLiveError.invalidAPIKey(issue) }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        // Google native Python SDK uses this header for WebSockets. Never put the key in URLs.
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpShouldHandleCookies = false
        return request
    }

    static func setup(model: String, languageCodes: [String], vocabulary: [String]) throws -> String {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.range(of: "\\Agemini-[A-Za-z0-9][A-Za-z0-9.-]{0,99}\\z", options: .regularExpression) != nil else {
            throw GeminiLiveError.invalidModel
        }
        guard languageCodes.count <= 16,
              languageCodes.allSatisfy({ $0.range(of: "\\A[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*\\z", options: .regularExpression) != nil && $0.utf8.count <= 64 }) else {
            throw GeminiLiveError.invalidLanguageCodes
        }
        guard vocabulary.count <= 1_000,
              vocabulary.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }),
              vocabulary.reduce(0, { $0 + $1.utf8.count }) <= 16_000 else {
            throw GeminiLiveError.invalidVocabulary
        }
        return try encode(["setup": [
            "model": "models/" + model,
            "generationConfig": ["responseModalities": ["TEXT"]],
            "inputAudioTranscription": [
                "mode": "VERBATIM",
                "languageCodes": languageCodes,
                "customVocabulary": vocabulary
            ],
            "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]]
        ]])
    }

    static func audio(_ bytes: Data) throws -> String {
        try encode(["realtimeInput": ["audio": ["mimeType": "audio/pcm;rate=16000", "data": bytes.base64EncodedString()]]])
    }

    private static func encode(_ json: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

struct GeminiLiveEvent: Sendable {
    var setupComplete = false
    var finalText: String?
    var interimText: String?
    var turnComplete = false
    var interrupted = false
    var rejected = false
    var goAway = false

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 262_144 else { throw GeminiLiveError.oversizedResponse }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiLiveError.invalidResponse
        }
        var result = Self()
        result.rejected = json["error"] != nil || json["code"] != nil || json["toolCall"] != nil
        result.goAway = json["goAway"] != nil
        if let setup = json["setupComplete"] {
            guard setup is [String: Any] else { throw GeminiLiveError.invalidResponse }
            result.setupComplete = true
        }
        if let rawContent = json["serverContent"] {
            guard let content = rawContent as? [String: Any] else { throw GeminiLiveError.invalidResponse }
            result.finalText = try textField(content["inputTranscription"])
            result.interimText = try textField(content["interimInputTranscription"])
            result.turnComplete = content["turnComplete"] as? Bool ?? false
            result.interrupted = content["interrupted"] as? Bool ?? false
            // modelTurn/outputTranscription are deliberately never used as the dictation text.
        }
        return result
    }

    private static func textField(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        guard let object = value as? [String: Any] else { throw GeminiLiveError.invalidResponse }
        if let text = object["text"] {
            guard let text = text as? String else { throw GeminiLiveError.invalidResponse }
            return text
        }
        return ""
    }
}

struct GeminiLiveTranscript {
    private(set) var committed = ""
    private(set) var interim = ""
    var hasInterim: Bool { !interim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var preview: String { committed + interim }

    @discardableResult
    mutating func consume(_ event: GeminiLiveEvent) throws -> Bool {
        let old = preview
        // A final speech segment replaces the speculative preview for that segment.
        if let text = event.finalText {
            try validate(text)
            committed += text
            interim = ""
        }
        // If a message also starts a new interim segment, preserve that new speculation.
        if let text = event.interimText {
            try validate(text)
            interim = text
        }
        guard committed.utf8.count + interim.utf8.count <= 64_000 else {
            throw GeminiLiveError.oversizedResponse
        }
        return old != preview
    }

    private func validate(_ text: String) throws {
        guard !text.unicodeScalars.contains(where: {
            ($0.value < 32 && $0.value != 9 && $0.value != 10 && $0.value != 13) || $0.value == 127
        }) else { throw GeminiLiveError.invalidResponse }
    }
}

protocol GeminiLiveTransport: Sendable {
    func connect(request: URLRequest) throws
    func send(_ text: String) async throws
    func receive() async throws -> Data
    /// Must promptly unblock all pending send/receive calls.
    func cancel()
}

private final class GeminiNativeLiveTransport: @unchecked Sendable, GeminiLiveTransport {
    private let lock = NSLock()
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var cancelled = false

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 180
        session = URLSession(configuration: configuration, delegate: GeminiLiveRedirectBlocker(), delegateQueue: nil)
    }

    func connect(request: URLRequest) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, task == nil else { throw CancellationError() }
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 262_144
        task = socket
        socket.resume()
    }

    private func socket() throws -> URLSessionWebSocketTask {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, let task else { throw CancellationError() }
        return task
    }

    func send(_ text: String) async throws { try await socket().send(.string(text)) }

    func receive() async throws -> Data {
        switch try await socket().receive() {
        case .data(let bytes): return bytes
        case .string(let text): return Data(text.utf8)
        @unknown default: throw GeminiLiveError.invalidResponse
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let socket = task
        task = nil
        lock.unlock()
        socket?.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    deinit { task?.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}

private final class GeminiLiveRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
