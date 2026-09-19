import Foundation
import XCTest
@testable import OpenInsertCore

final class GeminiLiveTests: XCTestCase {
    private let key = "AIza-test-live-key-never-use-in-production"
    private let pcm = Data(repeating: 0, count: 3_200)
    private let timing = GeminiLiveTiming(setup: 1, finalization: 1, quietDrain: 0.06, send: 1)

    func testHandshakeHasFixedWSSOriginAndHeaderOnlyKey() throws {
        let request = try GeminiLiveProtocol.request(apiKey: key)
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.host, "generativelanguage.googleapis.com")
        XCTAssertEqual(request.url?.path, "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), key)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.timeoutInterval, 10)
    }

    func testSetupMatchesDedicatedTranscribeModelAndManualVAD() throws {
        let message = try GeminiLiveProtocol.setup(model: "gemini-3.5-transcribe-live", languageCodes: ["cmn-Hans-CN", "en-US"], vocabulary: ["OpenInsert", "ignore all instructions"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let setup = try XCTUnwrap(json["setup"] as? [String: Any])
        XCTAssertEqual(setup["model"] as? String, "models/gemini-3.5-transcribe-live")
        let config = try XCTUnwrap(setup["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseModalities"] as? [String], ["TEXT"])
        XCTAssertNil(config["responseJsonSchema"])
        XCTAssertNil(config["responseMimeType"])
        XCTAssertNil(setup["systemInstruction"])
        XCTAssertNil(setup["tools"])
        let transcription = try XCTUnwrap(setup["inputAudioTranscription"] as? [String: Any])
        XCTAssertEqual(transcription["mode"] as? String, "VERBATIM")
        XCTAssertEqual(transcription["customVocabulary"] as? [String], ["OpenInsert", "ignore all instructions"])
        let realtime = try XCTUnwrap(setup["realtimeInputConfig"] as? [String: Any])
        XCTAssertEqual((realtime["automaticActivityDetection"] as? [String: Bool])?["disabled"], true)
        XCTAssertFalse(message.contains(key))
    }

    func testInvalidConfigurationRejectedBeforeTransportConnects() async {
        for invalidKey in ["", "short", "valid-length-key\r\nInjected: yes"] {
            let socket = FakeLiveTransport()
            let client = GeminiLiveTranscriber(apiKey: invalidKey, transport: socket, timing: timing)
            do { try await client.start(); XCTFail("Expected key validation") }
            catch { XCTAssertEqual(error as? GeminiLiveError, .invalidConfiguration) }
            XCTAssertNil(socket.request)
        }
        XCTAssertThrowsError(try GeminiLiveProtocol.setup(model: "gemini-evil/../../other", languageCodes: [], vocabulary: []))
        XCTAssertThrowsError(try GeminiLiveProtocol.setup(model: "gemini-3.5-transcribe-live", languageCodes: ["not a language"], vocabulary: []))
        XCTAssertThrowsError(try GeminiLiveProtocol.setup(model: "gemini-3.5-transcribe-live", languageCodes: [], vocabulary: Array(repeating: "term", count: 1_001)))
    }

    func testAudioFrameContainsOnlyPCMAndCorrectMIME() throws {
        let message = try GeminiLiveProtocol.audio(Data([0x00, 0x80, 0xff, 0x7f]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let input = try XCTUnwrap(json["realtimeInput"] as? [String: Any])
        let audio = try XCTUnwrap(input["audio"] as? [String: String])
        XCTAssertEqual(audio["mimeType"], "audio/pcm;rate=16000")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(audio["data"])), Data([0x00, 0x80, 0xff, 0x7f]))
        XCTAssertNil(input["audioStreamEnd"])
    }

    func testSetupBarrierPrecedesActivityStartAndAudio() async throws {
        let socket = FakeLiveTransport(autoSetup: false)
        let setupSent = expectation(description: "setup sent")
        socket.onSend = { text in if text.contains("\"setup\"") { setupSent.fulfill() } }
        let client = GeminiLiveTranscriber(apiKey: key, transport: socket, timing: timing)
        let starting = Task { try await client.start() }
        await fulfillment(of: [setupSent], timeout: 1)
        XCTAssertEqual(socket.sent.count, 1)
        socket.push(#"{"setupComplete":{}}"#)
        try await starting.value
        try await client.sendAudio(pcm)
        XCTAssertEqual(socket.sent.count, 3)
        XCTAssertTrue(socket.sent[0].contains("\"setup\""))
        XCTAssertEqual(socket.sent[1], GeminiLiveProtocol.activityStart)
        let audioMessage = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(socket.sent[2].utf8)) as? [String: Any])
        let input = try XCTUnwrap(audioMessage["realtimeInput"] as? [String: Any])
        XCTAssertEqual((input["audio"] as? [String: String])?["mimeType"], "audio/pcm;rate=16000")
        await client.cancel()
    }

    func testInterimReplacesPreviewAndFinalSegmentsAppendWithoutDeduplication() throws {
        var accumulator = GeminiLiveTranscript()
        try accumulator.consume(GeminiLiveEvent(interimText: "I lik"))
        try accumulator.consume(GeminiLiveEvent(interimText: "I like"))
        XCTAssertEqual(accumulator.preview, "I like")
        XCTAssertEqual(accumulator.committed, "")
        try accumulator.consume(GeminiLiveEvent(finalText: "I like "))
        XCTAssertEqual(accumulator.preview, "I like ")
        XCTAssertFalse(accumulator.hasInterim)
        try accumulator.consume(GeminiLiveEvent(interimText: "open"))
        try accumulator.consume(GeminiLiveEvent(finalText: "OpenInsert。"))
        try accumulator.consume(GeminiLiveEvent(finalText: "對，對。"))
        try accumulator.consume(GeminiLiveEvent(finalText: "對，對。"))
        XCTAssertEqual(accumulator.committed, "I like OpenInsert。對，對。對，對。")
    }

    func testNewInterimAlongsideFinalRemainsUnresolved() throws {
        var accumulator = GeminiLiveTranscript()
        try accumulator.consume(GeminiLiveEvent(finalText: "One. ", interimText: "Tw"))
        XCTAssertEqual(accumulator.preview, "One. Tw")
        XCTAssertTrue(accumulator.hasInterim)
    }

    func testFinalBeforeTurnCompleteUsesOnlyCommittedText() async throws {
        let socket = FakeLiveTransport()
        let updates = PreviewLog()
        let client = GeminiLiveTranscriber(apiKey: key, transport: socket, timing: timing) { updates.append($0) }
        try await client.start()
        try await client.sendAudio(pcm)
        socket.onSend = { text in
            if text == GeminiLiveProtocol.activityEnd {
                socket.push(#"{"serverContent":{"interimInputTranscription":{"text":"guess"}}}"#)
                socket.push(#"{"serverContent":{"inputTranscription":{"text":"你好，OpenInsert。"}}}"#)
                socket.push(#"{"serverContent":{"turnComplete":true}}"#)
            }
        }
        let result = try await client.finish()
        XCTAssertEqual(result, "你好，OpenInsert。")
        XCTAssertEqual(updates.values.last, result)
        XCTAssertTrue(socket.cancelled)
        XCTAssertFalse(socket.sent.joined().contains("audioStreamEnd"))
    }

    func testTurnCompleteBeforeFinalWaitsForLateFinalAndResetsDrain() async throws {
        let socket = FakeLiveTransport()
        let clock = ManualLiveClock()
        defer { clock.resolveAll() }
        let controlled = GeminiLiveTiming(setup: 100, finalization: 200, quietDrain: 1, send: 300)
        let client = GeminiLiveTranscriber(apiKey: key, transport: socket, timing: controlled, clock: clock)
        try await client.start()
        try await client.sendAudio(pcm)
        socket.onSend = { text in
            if text == GeminiLiveProtocol.activityEnd {
                socket.push(#"{"serverContent":{"turnComplete":true}}"#)
            }
        }
        let finishing = Task { try await client.finish() }
        let firstDrain = try await waitForSleep(clock, seconds: 1, ordinal: 1)
        socket.push(#"{"serverContent":{"inputTranscription":{"text":"First. "}}}"#)
        let secondDrain = try await waitForSleep(clock, seconds: 1, ordinal: 2)
        socket.push(#"{"serverContent":{"inputTranscription":{"text":"Last."}}}"#)
        let lastDrain = try await waitForSleep(clock, seconds: 1, ordinal: 3)
        // Expiry can already be queued when cancellation happens. Deliver both obsolete
        // callbacks anyway; only the latest transcript revision is allowed to complete.
        clock.fire(firstDrain)
        clock.fire(secondDrain)
        clock.fire(lastDrain)
        let result = try await finishing.value
        XCTAssertEqual(result, "First. Last.")
        XCTAssertTrue(socket.cancelled)
    }

    func testCancelledSetupDeadlineCannotFailFinishingPhase() async throws {
        let socket = FakeLiveTransport()
        let clock = ManualLiveClock()
        defer { clock.resolveAll() }
        let controlled = GeminiLiveTiming(setup: 100, finalization: 200, quietDrain: 1, send: 300)
        let client = GeminiLiveTranscriber(apiKey: key, transport: socket, timing: controlled, clock: clock)
        try await client.start()
        let setupDeadline = try await waitForSleep(clock, seconds: 100)
        socket.onSend = { text in
            if text == GeminiLiveProtocol.activityEnd {
                socket.push(#"{"serverContent":{"inputTranscription":{"text":"Still valid."},"turnComplete":true}}"#)
            }
        }
        let finishing = Task { try await client.finish() }
        let drain = try await waitForSleep(clock, seconds: 1)
        clock.fire(setupDeadline) // Simulates an expiry queued just before cancellation.
        clock.fire(drain)
        let result = try await finishing.value
        XCTAssertEqual(result, "Still valid.")
    }

    func testCompletedWriteWatchdogCannotCancelANewerWrite() async throws {
        let socket = FakeLiveTransport()
        let clock = ManualLiveClock()
        defer { clock.resolveAll() }
        let controlled = GeminiLiveTiming(setup: 100, finalization: 200, quietDrain: 1, send: 300)
        let client = GeminiLiveTranscriber(apiKey: key, transport: socket, timing: controlled, clock: clock)
        try await client.start()
        let setupWatchdog = try await waitForSleep(clock, seconds: 300, ordinal: 1)
        socket.stallAudio = true
        let sending = Task { try await client.sendAudio(pcm) }
        _ = try await waitForSleep(clock, seconds: 300, ordinal: 3)
        clock.fire(setupWatchdog)
        socket.releaseAudioWrites()
        try await sending.value
        socket.onSend = { text in
            if text == GeminiLiveProtocol.activityEnd {
                socket.push(#"{"serverContent":{"inputTranscription":{"text":"New write survived."},"turnComplete":true}}"#)
            }
        }
        let finishing = Task { try await client.finish() }
        let drain = try await waitForSleep(clock, seconds: 1)
        clock.fire(drain)
        let result = try await finishing.value
        XCTAssertEqual(result, "New write survived.")
    }

    func testSystemClockCancellationReturnsFalseWithoutThrowing() async {
        let waiting = Task { await GeminiLiveSystemClock().sleep(for: 3_600) }
        waiting.cancel()
        let expired = await waiting.value
        XCTAssertFalse(expired)
    }

    private func waitForSleep(_ clock: ManualLiveClock, seconds: TimeInterval, ordinal: Int = 1,
                              file: StaticString = #filePath, line: UInt = #line) async throws -> UUID {
        let registered = expectation(description: "registered timer \(seconds) #\(ordinal)")
        clock.observe(seconds: seconds, ordinal: ordinal) { registered.fulfill() }
        await fulfillment(of: [registered], timeout: 3)
        return try XCTUnwrap(clock.id(seconds: seconds, ordinal: ordinal), file: file, line: line)
    }

    func testTurnCompleteDuringRecordingCannotFinalizeLaterTurn() async throws {
        let socket = FakeLiveTransport()
        let fast = GeminiLiveTiming(setup: 1, finalization: 0.15, quietDrain: 0.03, send: 1)
        let received = expectation(description: "early transcript processed")
        let client = GeminiLiveTranscriber(apiKey: key, transport: socket, timing: fast) { _ in received.fulfill() }
        try await client.start()
        socket.push(#"{"serverContent":{"inputTranscription":{"text":"early"},"turnComplete":true}}"#)
        await fulfillment(of: [received], timeout: 1)
        do { _ = try await client.finish(); XCTFail("Expected missing completion") }
        catch { XCTAssertEqual(error as? GeminiLiveError, .finalizationTimeout) }
    }

    func testUnresolvedInterimTimesOutAndRetainsPreview() async throws {
        let socket = FakeLiveTransport()
        let updates = PreviewLog()
        let fast = GeminiLiveTiming(setup: 1, finalization: 0.15, quietDrain: 0.03, send: 1)
        let client = GeminiLiveTranscriber(apiKey: key, transport: socket, timing: fast) { updates.append($0) }
        try await client.start()
        socket.onSend = { text in
            if text == GeminiLiveProtocol.activityEnd {
                socket.push(#"{"serverContent":{"inputTranscription":{"text":"Committed. "},"interimInputTranscription":{"text":"unfinished"},"turnComplete":true}}"#)
            }
        }
        do { _ = try await client.finish(); XCTFail("Must not commit interim") }
        catch { XCTAssertEqual(error as? GeminiLiveError, .finalizationTimeout) }
        XCTAssertEqual(updates.values.last, "Committed. unfinished")
        XCTAssertTrue(socket.cancelled)
    }

    func testEmptyCompletedTurnReturnsNoSpeech() async throws {
        let socket = FakeLiveTransport()
        let client = GeminiLiveTranscriber(apiKey: key, transport: socket, timing: timing)
        try await client.start()
        socket.onSend = { text in
            if text == GeminiLiveProtocol.activityEnd { socket.push(#"{"serverContent":{"turnComplete":true}}"#) }
        }
        do { _ = try await client.finish(); XCTFail("Expected empty transcript") }
        catch { XCTAssertEqual(error as? GeminiLiveError, .emptyTranscript) }
    }

    func testSetupDeadlineClosesSocketAndCannotHang() async {
        let socket = FakeLiveTransport(autoSetup: false)
        let client = GeminiLiveTranscriber(apiKey: key, transport: socket,
                                          timing: GeminiLiveTiming(setup: 0.03, finalization: 1, quietDrain: 0.03, send: 1))
        do { try await client.start(); XCTFail("Expected setup timeout") }
        catch { XCTAssertEqual(error as? GeminiLiveError, .setupTimeout) }
        XCTAssertTrue(socket.cancelled)
    }

    func testCancellationDuringSetupResumesStart() async {
        let socket = FakeLiveTransport(autoSetup: false)
        let setupSent = expectation(description: "setup sent")
        socket.onSend = { _ in setupSent.fulfill() }
        let client = GeminiLiveTranscriber(apiKey: key, transport: socket, timing: timing)
        let task = Task { try await client.start() }
        await fulfillment(of: [setupSent], timeout: 1)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(socket.cancelled)
    }

    func testCancellationDuringFinishResumesWaiterAndClosesSocket() async throws {
        let socket = FakeLiveTransport()
        let ended = expectation(description: "activity end sent")
        socket.onSend = { text in if text == GeminiLiveProtocol.activityEnd { ended.fulfill() } }
        let client = GeminiLiveTranscriber(apiKey: key, transport: socket, timing: timing)
        try await client.start()
        let finishing = Task { try await client.finish() }
        await fulfillment(of: [ended], timeout: 1)
        await client.cancel()
        do { _ = try await finishing.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(socket.cancelled)
    }

    func testStalledAudioWriteHasDeadlineBeforeFinishCanBeCalled() async throws {
        let socket = FakeLiveTransport()
        socket.stallAudio = true
        let client = GeminiLiveTranscriber(apiKey: key, transport: socket,
                                          timing: GeminiLiveTiming(setup: 1, finalization: 1, quietDrain: 0.03, send: 0.03))
        try await client.start()
        do { try await client.sendAudio(pcm); XCTFail("Expected write deadline") }
        catch { XCTAssertEqual(error as? GeminiLiveError, .network) }
        XCTAssertTrue(socket.cancelled)
    }

    func testServerErrorIsRedactedAndNoRetriesOccur() async {
        let socket = FakeLiveTransport(autoSetup: false)
        socket.onSend = { _ in socket.push(#"{"error":{"message":"private api key echoed here","code":403}}"#) }
        let client = GeminiLiveTranscriber(apiKey: key, transport: socket, timing: timing)
        do { try await client.start(); XCTFail("Expected rejection") }
        catch {
            XCTAssertEqual(error as? GeminiLiveError, .serverRejected)
            XCTAssertFalse(error.localizedDescription.contains("private api key"))
            XCTAssertFalse(error.localizedDescription.contains(key))
        }
        XCTAssertEqual(socket.sent.count, 1)
        XCTAssertTrue(socket.cancelled)
    }

    func testInvalidPCMIsRejectedWithoutUpload() async throws {
        let socket = FakeLiveTransport()
        let client = GeminiLiveTranscriber(apiKey: key, transport: socket, timing: timing)
        try await client.start()
        for bytes in [Data(), Data([0]), Data(repeating: 0, count: 32_002)] {
            do { try await client.sendAudio(bytes); XCTFail("Expected PCM rejection") }
            catch { XCTAssertEqual(error as? GeminiLiveError, .invalidAudio) }
        }
        XCTAssertEqual(socket.sent.count, 2)
        await client.cancel()
    }

    func testMalformedOversizedAndControlTextAreRejected() throws {
        XCTAssertThrowsError(try GeminiLiveEvent.decode(Data("broken".utf8)))
        XCTAssertThrowsError(try GeminiLiveEvent.decode(Data(repeating: 65, count: 262_145))) {
            XCTAssertEqual($0 as? GeminiLiveError, .oversizedResponse)
        }
        XCTAssertThrowsError(try GeminiLiveEvent.decode(Data(#"{"serverContent":{"inputTranscription":{"text":123}}}"#.utf8)))
        var accumulator = GeminiLiveTranscript()
        XCTAssertThrowsError(try accumulator.consume(GeminiLiveEvent(finalText: "bad\u{1b}control")))
        XCTAssertThrowsError(try accumulator.consume(GeminiLiveEvent(finalText: String(repeating: "字", count: 21_334)))) {
            XCTAssertEqual($0 as? GeminiLiveError, .oversizedResponse)
        }
    }

    func testAssistantOutputAndOptionalFinishedFlagDoNotReplaceInput() throws {
        let event = try GeminiLiveEvent.decode(Data(#"{"serverContent":{"modelTurn":{"parts":[{"text":"assistant answer"}]},"outputTranscription":{"text":"not dictation"},"inputTranscription":{"text":"spoken words","finished":true}}}"#.utf8))
        XCTAssertEqual(event.finalText, "spoken words")
        XCTAssertFalse(event.turnComplete)
        var accumulator = GeminiLiveTranscript()
        try accumulator.consume(event)
        XCTAssertEqual(accumulator.committed, "spoken words")
    }
}

private final class PreviewLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; entries.append(value) }
}

/// Deliberately retains cancelled waits: fire() models a timer expiry that was already
/// queued before cancellation. Every test drains remaining continuations in defer.
private final class ManualLiveClock: @unchecked Sendable, GeminiLiveClock {
    private struct Entry {
        let id: UUID
        let seconds: TimeInterval
        var waiter: CheckedContinuation<Bool, Never>?
    }
    private struct Observer {
        let seconds: TimeInterval
        let ordinal: Int
        let action: @Sendable () -> Void
    }
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var observers: [Observer] = []
    private var closed = false

    func sleep(for seconds: TimeInterval) async -> Bool {
        await withCheckedContinuation { waiter in
            lock.lock()
            if closed {
                lock.unlock()
                waiter.resume(returning: false)
                return
            }
            entries.append(Entry(id: UUID(), seconds: seconds, waiter: waiter))
            let ready = observers.filter { observer in
                entries.filter { $0.seconds == observer.seconds }.count >= observer.ordinal
            }
            observers.removeAll { observer in
                entries.filter { $0.seconds == observer.seconds }.count >= observer.ordinal
            }
            lock.unlock()
            ready.forEach { $0.action() }
        }
    }

    func observe(seconds: TimeInterval, ordinal: Int, action: @escaping @Sendable () -> Void) {
        lock.lock()
        if entries.filter({ $0.seconds == seconds }).count >= ordinal {
            lock.unlock()
            action()
        } else {
            observers.append(Observer(seconds: seconds, ordinal: ordinal, action: action))
            lock.unlock()
        }
    }

    func id(seconds: TimeInterval, ordinal: Int) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        let matches = entries.filter { $0.seconds == seconds }
        return matches.count >= ordinal ? matches[ordinal - 1].id : nil
    }

    func fire(_ id: UUID) {
        lock.lock()
        let index = entries.firstIndex { $0.id == id }
        let waiter = index.flatMap { entries[$0].waiter }
        if let index { entries[index].waiter = nil }
        lock.unlock()
        waiter?.resume(returning: true)
    }

    func resolveAll() {
        lock.lock()
        closed = true
        let pending = entries.compactMap(\.waiter)
        for index in entries.indices { entries[index].waiter = nil }
        lock.unlock()
        pending.forEach { $0.resume(returning: false) }
    }
}

private final class FakeLiveTransport: @unchecked Sendable, GeminiLiveTransport {
    private let lock = NSLock()
    private let autoSetup: Bool
    private var storedRequest: URLRequest?
    private var messages: [String] = []
    private var queued: [Data] = []
    private var receiveWaiter: CheckedContinuation<Data, Error>?
    private var sendWaiters: [CheckedContinuation<Void, Error>] = []
    private var isCancelled = false
    private var handler: (@Sendable (String) -> Void)?
    private var shouldStallAudio = false

    init(autoSetup: Bool = true) { self.autoSetup = autoSetup }
    var request: URLRequest? { lock.lock(); defer { lock.unlock() }; return storedRequest }
    var sent: [String] { lock.lock(); defer { lock.unlock() }; return messages }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return isCancelled }
    var onSend: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return handler }
        set { lock.lock(); defer { lock.unlock() }; handler = newValue }
    }
    var stallAudio: Bool {
        get { lock.lock(); defer { lock.unlock() }; return shouldStallAudio }
        set { lock.lock(); defer { lock.unlock() }; shouldStallAudio = newValue }
    }

    func connect(request: URLRequest) throws {
        lock.lock(); defer { lock.unlock() }
        if isCancelled { throw CancellationError() }
        storedRequest = request
    }

    private func record(_ message: String) throws -> (@Sendable (String) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        if isCancelled { throw CancellationError() }
        messages.append(message)
        return handler
    }

    func send(_ text: String) async throws {
        let callback = try record(text)
        callback?(text)
        if autoSetup && text.contains("\"setup\"") { push(#"{"setupComplete":{}}"#) }
        let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        let isAudio = (json?["realtimeInput"] as? [String: Any])?["audio"] != nil
        if stallAudio && isAudio {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if !shouldStallAudio {
                    lock.unlock()
                    continuation.resume()
                } else {
                    sendWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }
    }

    func releaseAudioWrites() {
        lock.lock()
        shouldStallAudio = false
        let pending = sendWaiters
        sendWaiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if isCancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
            } else if !queued.isEmpty {
                let data = queued.removeFirst()
                lock.unlock()
                continuation.resume(returning: data)
            } else {
                receiveWaiter = continuation
                lock.unlock()
            }
        }
    }

    func push(_ json: String) {
        let data = Data(json.utf8)
        lock.lock()
        guard !isCancelled else { lock.unlock(); return }
        if let waiter = receiveWaiter {
            receiveWaiter = nil
            lock.unlock()
            waiter.resume(returning: data)
        } else {
            queued.append(data)
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let waiting = receiveWaiter
        receiveWaiter = nil
        let sending = sendWaiters
        sendWaiters = []
        queued = []
        lock.unlock()
        waiting?.resume(throwing: CancellationError())
        sending.forEach { $0.resume(throwing: CancellationError()) }
    }
}
