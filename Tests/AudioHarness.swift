import AVFoundation
import Foundation

// Standalone native-audio harness: ./scripts/test-audio.sh.
// No StreamingAudioRecorder is instantiated, so no microphone is accessed.
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "StreamTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func floats(rate: Double, channels: AVAudioChannelCount, offset: Int, frames: Int, tail: Bool = false, rightOnly: Bool = false) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for channel in 0..<Int(channels) {
        for frame in 0..<frames {
            let index = offset + frame
            let amplitude = tail ? (index >= Int(rate) - 120 ? 0.5 : 0) : 0.5 * sin(2 * .pi * 440 * Double(index) / rate)
            buffer.floatChannelData![channel][frame] = Float(rightOnly && channel == 0 ? 0 : amplitude)
        }
    }
    return buffer
}
func samples(_ data: Data) -> [Int16] {
    data.withUnsafeBytes { bytes in
        stride(from: 0, to: bytes.count, by: 2).map { Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: Int16.self)) }
    }
}
func checkConverter(rate: Double, channels: AVAudioChannelCount, tail: Bool = false, rightOnly: Bool = false) throws {
    let example = floats(rate: rate, channels: channels, offset: 0, frames: 1)
    let converter = try StreamingPCMConverter(inputFormat: example.format)
    let sizes = [31, 1024, 4096, 127, 512]
    var output = Data()
    var offset = 0
    var iteration = 0
    while offset < Int(rate) {
        let size = min(sizes[iteration % sizes.count], Int(rate) - offset)
        let buffer = floats(rate: rate, channels: channels, offset: offset, frames: size, tail: tail, rightOnly: rightOnly)
        let captured = try CapturedPCM(buffer)
        // Poison the original after capture to verify ownership was copied.
        for channel in 0..<Int(channels) { buffer.floatChannelData![channel].update(repeating: 0, count: size) }
        for chunk in try converter.convert(captured) { output.append(chunk) }
        offset += size
        iteration += 1
    }
    let priorFlush = output.count / 2
    for chunk in try converter.finish() { output.append(chunk) }
    let result = samples(output)
    try check(abs(result.count - 16000) <= 1, "Frame count \(rate) Hz: \(result.count), before flush \(priorFlush)")
    if tail {
        try check(result.suffix(100).contains(where: { abs(Int($0)) > 1000 }), "Final audio tail lost")
    } else {
        let crossings = zip(result, result.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        try check(abs(crossings - 440) <= 2, "Frequency incorrect: \(crossings)")
        let rms = sqrt(result.map { pow(Double($0) / 32768, 2) }.reduce(0, +) / Double(result.count))
        try check(rms > 0.08 && rms < 0.8, "Bad amplitude: \(rms)")
    }
    let secondFinish = try converter.finish(); try check(secondFinish.isEmpty, "Repeated finish emits duplicate tail")
    print("PASS converter \(rate) Hz channels=\(channels) tail=\(tail) rightOnly=\(rightOnly): \(result.count) frames (flush +\(result.count-priorFlush))")
}
@main struct Runner {
    static func main() async throws {
        for rate in [8000.0, 16000.0, 44100.0, 48000.0, 96000.0] {
            try checkConverter(rate: rate, channels: 1)
            try checkConverter(rate: rate, channels: 2, rightOnly: true)
        }
        try checkConverter(rate: 48000, channels: 1, tail: true)
        try await checkQueue()
        try await checkOverflow()
        try await checkCancellation()
        try await checkHandshakeBuffer()
    }
    static func checkQueue() async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(128)) { continuation = $0 }
        let queue = try StreamingPCMQueue(format: format, continuation: continuation, onFailure: {})
        let consumer = Task { () throws -> [Data] in
            var chunks: [Data] = []
            for try await chunk in stream { chunks.append(chunk) }
            return chunks
        }
        // 1.05 seconds, including a non-100-ms tail. Pause briefly to avoid
        // intentionally exceeding the independently bounded conversion queue.
        let total = 50400
        var offset = 0
        while offset < total {
            let count = min(1024, total-offset)
            queue.accept(floats(rate: 48000, channels: 1, offset: offset, frames: count))
            offset += count
            try await Task.sleep(nanoseconds: 100_000)
        }
        queue.finish()
        let chunks = try await consumer.value
        try check(chunks.count == 11, "Queue chunk count \(chunks.count)")
        try check(chunks.dropLast().allSatisfy { $0.count == 3200 }, "Not 100-ms chunks")
        try check(chunks.last!.count == 1600, "Tail bytes \(chunks.last!.count)")
        try check(chunks.reduce(0) { $0 + $1.count } == 33600, "Queue sample loss")
        queue.finish()
        print("PASS queue: 10 x 3200-byte chunks + 1600-byte tail, all 16800 samples preserved")
    }
    static func checkOverflow() async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(2)) { continuation = $0 }
        let failed = DispatchSemaphore(value: 0)
        let queue = try StreamingPCMQueue(format: format, continuation: continuation, onFailure: { failed.signal() })
        queue.accept(floats(rate: 48000, channels: 1, offset: 0, frames: 24000))
        queue.finish()
        try check(failed.wait(timeout: .now() + 5) == .success, "Overflow did not report failure")
        var count = 0
        do {
            for try await _ in stream { count += 1 }
            throw NSError(domain: "StreamTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Overflow finished without an error"])
        } catch StreamingRecorderError.networkBackpressure {
            try check(count == 2, "Overflow did not retain oldest chunks")
        }
        print("PASS overflow: two oldest chunks retained, explicit networkBackpressure failure")
    }
    static func checkCancellation() async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(128)) { continuation = $0 }
        let queue = try StreamingPCMQueue(format: format, continuation: continuation, onFailure: {})
        queue.cancel()
        queue.accept(floats(rate: 48000, channels: 1, offset: 0, frames: 24000))
        queue.finish()
        var count = 0
        do {
            for try await _ in stream { count += 1 }
            throw NSError(domain: "StreamTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cancellation finished successfully"])
        } catch is CancellationError {
            try check(count == 0, "Audio emitted after cancellation")
        }
        print("PASS cancellation: no chunks emitted after cancellation or subsequent accept/finish")
    }
    static func checkHandshakeBuffer() async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(128)) { continuation = $0 }
        let completed = DispatchSemaphore(value: 0)
        continuation.onTermination = { _ in completed.signal() }
        let queue = try StreamingPCMQueue(format: format, continuation: continuation, onFailure: {})
        // Deliberately do not consume until conversion and stream completion:
        // setup latency up to 12 seconds must retain the start of speech.
        queue.accept(floats(rate: 48000, channels: 1, offset: 0, frames: 576000))
        queue.finish()
        try check(completed.wait(timeout: .now() + 5) == .success, "Delayed-consumer stream did not complete")
        var chunks: [Data] = []
        for try await chunk in stream { chunks.append(chunk) }
        try check(chunks.count == 120 && chunks.allSatisfy { $0.count == 3200 }, "Handshake buffering lost audio")
        print("PASS delayed consumer: all 12 seconds retained as 120 chunks before subscription")
    }
}
