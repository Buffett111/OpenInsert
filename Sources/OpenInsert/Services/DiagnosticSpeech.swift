import AVFoundation
import Foundation

/// Synthesizes one public test sentence into memory. Never opens an input device,
/// plays audio, writes a recording, or accesses user text.
@MainActor
final class DiagnosticSpeech {
    static let sentence = "這是一段語音輸入測試。請使用繁體中文，並保留 OpenInsert 這個英文名稱。"
    private let synthesizer = AVSpeechSynthesizer()

    func render() async throws -> Data {
        let collector = SpeechPCMCollector()
        let timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) }
            catch { return }
            collector.resolve(.failure(DiagnosticSpeechError.unavailable))
            self?.synthesizer.stopSpeaking(at: .immediate)
        }
        defer { timeout.cancel(); synthesizer.stopSpeaking(at: .immediate) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.setContinuation(continuation)
                let utterance = AVSpeechUtterance(string: Self.sentence)
                utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
                utterance.rate = 0.5
                synthesizer.write(utterance) { buffer in collector.accept(buffer) }
            }
        } onCancel: {
            collector.resolve(.failure(CancellationError()))
            Task { @MainActor [weak self] in self?.synthesizer.stopSpeaking(at: .immediate) }
        }
    }
}

enum DiagnosticSpeechError: LocalizedError {
    case unavailable
    var errorDescription: String? { "無法產生本機測試語音；可以直接用快捷鍵測試自己的錄音。" }
}

private final class SpeechPCMCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: StreamingPCMConverter?
    private var pcm = Data()
    private var outcome: Result<Data, Error>?
    private var continuation: CheckedContinuation<Data, Error>?

    func setContinuation(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let outcome { lock.unlock(); continuation.resume(with: outcome); return }
        self.continuation = continuation
        lock.unlock()
    }

    func accept(_ buffer: AVAudioBuffer) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        do {
            guard let buffer = buffer as? AVAudioPCMBuffer else { throw DiagnosticSpeechError.unavailable }
            if buffer.frameLength == 0 {
                if let converter { for chunk in try converter.finish() { pcm.append(chunk) } }
                guard !pcm.isEmpty else { throw DiagnosticSpeechError.unavailable }
                let result = pcm
                lock.unlock()
                resolve(.success(result))
                return
            }
            if converter == nil { converter = try StreamingPCMConverter(inputFormat: buffer.format) }
            for chunk in try converter!.convert(CapturedPCM(buffer)) { pcm.append(chunk) }
            guard pcm.count <= 640_000 else { throw DiagnosticSpeechError.unavailable }
            lock.unlock()
        } catch { lock.unlock(); resolve(.failure(error)) }
    }

    func resolve(_ result: Result<Data, Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let waiter = continuation
        continuation = nil
        pcm.removeAll(keepingCapacity: false)
        converter = nil
        lock.unlock()
        waiter?.resume(with: result)
    }
}
