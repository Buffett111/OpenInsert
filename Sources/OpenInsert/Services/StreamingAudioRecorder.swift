import AVFoundation
import Foundation

/// Memory-only microphone capture. Chunks are raw 16 kHz mono signed Int16 PCM
/// in little-endian byte order (both supported macOS CPU architectures are LE).
@MainActor
final class StreamingAudioRecorder {
    private var engine: AVAudioEngine?
    private var pipeline: StreamingPCMQueue?
    private var observer: NSObjectProtocol?
    private var pendingStart: UUID?
    private var recordingID: UUID?
    private var startedAt: TimeInterval?
    private var lastDuration: TimeInterval = 0

    var duration: TimeInterval {
        guard let startedAt else { return lastDuration }
        return max(0, ProcessInfo.processInfo.systemUptime - startedAt)
    }

    var level: Float { pipeline?.level ?? 0 }

    func start() async throws -> AsyncThrowingStream<Data, Error> {
        try Task.checkCancellation()
        guard engine == nil, pendingStart == nil else { throw StreamingRecorderError.alreadyRecording }
        let attempt = UUID()
        pendingStart = attempt
        defer { if pendingStart == attempt { pendingStart = nil } }
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .audio)
        default: authorized = false
        }
        guard pendingStart == attempt else { throw CancellationError() }
        try Task.checkCancellation()
        guard authorized else { throw StreamingRecorderError.microphoneDenied }

        let audioEngine = AVAudioEngine()
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              format.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM else {
            throw StreamingRecorderError.noInputDevice
        }
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(128)) {
            continuation = $0
        }
        let queue = try StreamingPCMQueue(format: format, continuation: continuation) { [weak self] in
            Task { @MainActor in
                guard let self, self.recordingID == attempt else { return }
                self.stopHardware()
                self.pipeline = nil
            }
        }
        continuation.onTermination = { [weak queue] termination in
            if case .cancelled = termination { queue?.cancel() }
        }

        engine = audioEngine
        pipeline = queue
        recordingID = attempt
        // Only copied Data crosses the tap lifetime. No audio-engine-owned
        // AVAudioPCMBuffer is retained or accessed on the conversion queue.
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            queue.accept(buffer)
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: nil
        ) { [weak self, weak queue] _ in
            Task { @MainActor in
                guard let self, self.recordingID == attempt else { return }
                self.stopHardware()
                queue?.fail(StreamingRecorderError.inputDeviceChanged)
                self.pipeline = nil
            }
        }
        do {
            audioEngine.prepare()
            try audioEngine.start()
            try Task.checkCancellation()
            startedAt = ProcessInfo.processInfo.systemUptime
            lastDuration = 0
            return stream
        } catch {
            stopHardware()
            queue.cancel()
            pipeline = nil
            throw error
        }
    }

    /// Stops hardware immediately. The stream finishes only after every accepted
    /// tap buffer and the resampler's remaining tail have been emitted.
    func stop() {
        pendingStart = nil
        let queue = pipeline
        stopHardware()
        pipeline = nil
        queue?.finish()
    }

    func cancel() {
        pendingStart = nil
        let queue = pipeline
        stopHardware()
        pipeline = nil
        queue?.cancel()
    }

    private func stopHardware() {
        lastDuration = duration
        startedAt = nil
        recordingID = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        pipeline?.cancel()
    }
}

enum StreamingRecorderError: LocalizedError {
    case alreadyRecording, microphoneDenied, noInputDevice, conversionFailed
    case inputDeviceChanged, captureOverflow, networkBackpressure

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A recording is already in progress."
        case .microphoneDenied:
            return "Enable OpenInsert in System Settings → Privacy & Security → Microphone."
        case .noInputDevice: return "No usable microphone is available. Connect an input device and try again."
        case .conversionFailed: return "The microphone audio could not be converted. This dictation was stopped."
        case .inputDeviceChanged: return "The microphone configuration changed or disconnected. Please start a new dictation."
        case .captureOverflow: return "Audio processing could not keep up with the microphone. This dictation was stopped without silently omitting audio."
        case .networkBackpressure: return "The connection could not keep up with live audio. This dictation was stopped without silently omitting audio."
        }
    }
}

/// All converter calls run on workQueue. The lock covers only admission,
/// bounded pending-work accounting and completion; it never wraps converter work.
final class StreamingPCMQueue: @unchecked Sendable {
    private let workQueue = DispatchQueue(label: "org.openinsert.audio-conversion", qos: .userInitiated)
    private let lock = NSLock()
    private let converter: StreamingPCMConverter
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let onFailure: () -> Void
    private var accepting = true
    private var ended = false
    private var ending = false
    private var pendingCount = 0
    private var meter: Float = 0
    // Conversion-queue-only aggregation: 1,600 samples = 100 ms = 3,200 bytes.
    private var pendingPCM = Data()
    private let chunkBytes = 3_200
    private let maximumPendingBuffers = 32

    init(format: AVAudioFormat, continuation: AsyncThrowingStream<Data, Error>.Continuation,
         onFailure: @escaping () -> Void) throws {
        converter = try StreamingPCMConverter(inputFormat: format)
        self.continuation = continuation
        self.onFailure = onFailure
    }

    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return meter
    }

    func accept(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard accepting, !ended else { lock.unlock(); return }
        guard pendingCount < maximumPendingBuffers else {
            accepting = false
            lock.unlock()
            fail(StreamingRecorderError.captureOverflow)
            return
        }
        let captured: CapturedPCM
        do { captured = try CapturedPCM(buffer) }
        catch { lock.unlock(); fail(error); return }
        pendingCount += 1
        // Enqueue while holding the admission lock, so finish() is ordered after
        // every accepted buffer even when called concurrently with a tap.
        workQueue.async { [self] in
            defer {
                lock.lock(); pendingCount -= 1; lock.unlock()
            }
            guard !isEnded else { return }
            do {
                for chunk in try converter.convert(captured) { try append(chunk) }
            } catch { fail(error) }
        }
        lock.unlock()
    }

    func finish() {
        lock.lock()
        guard !ended, !ending else { lock.unlock(); return }
        accepting = false
        ending = true
        workQueue.async { [self] in
            guard !isEnded else { return }
            do {
                for chunk in try converter.finish() { try append(chunk) }
                if !pendingPCM.isEmpty {
                    try emit(pendingPCM)
                    pendingPCM.removeAll(keepingCapacity: false)
                }
                complete(error: nil)
            } catch { fail(error) }
        }
        lock.unlock()
    }

    func cancel() { complete(error: CancellationError()) }

    func fail(_ error: Error) { complete(error: error) }

    private var isEnded: Bool {
        lock.lock(); defer { lock.unlock() }
        return ended
    }

    private func complete(error: Error?) {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        accepting = false
        ended = true
        meter = 0
        lock.unlock()
        // Continuation callbacks may re-enter cancel(); never finish under lock.
        continuation.finish(throwing: error)
        if error != nil { onFailure() }
    }

    private func emit(_ chunk: Data) throws {
        guard !chunk.isEmpty else { return }
        guard !isEnded else { throw CancellationError() }
        switch continuation.yield(chunk) {
        case .enqueued:
            let rms: Float = chunk.withUnsafeBytes { bytes in
                let count = bytes.count / 2
                guard count > 0 else { return 0 }
                var sum = 0.0
                for offset in stride(from: 0, to: bytes.count, by: 2) {
                    let sample = bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self)
                    let value = Double(Int16(littleEndian: sample)) / 32_768
                    sum += value * value
                }
                return Float(sqrt(sum / Double(count)))
            }
            lock.lock()
            if !ended { meter = min(1, rms) }
            lock.unlock()
        case .dropped: throw StreamingRecorderError.networkBackpressure
        case .terminated: throw CancellationError()
        @unknown default: throw StreamingRecorderError.networkBackpressure
        }
    }

    private func append(_ data: Data) throws {
        pendingPCM.append(data)
        while pendingPCM.count >= chunkBytes {
            try emit(Data(pendingPCM.prefix(chunkBytes)))
            pendingPCM.removeFirst(chunkBytes)
        }
    }
}

/// A byte snapshot made inside the microphone tap. This also provides a test
/// seam for synthetic audio; it does not require microphone access.
struct CapturedPCM: Sendable {
    let frames: AVAudioFrameCount
    let buffers: [Data]

    init(_ buffer: AVAudioPCMBuffer) throws {
        frames = buffer.frameLength
        buffers = try UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).map { entry in
            guard let pointer = entry.mData else { throw StreamingRecorderError.conversionFailed }
            return Data(bytes: pointer, count: Int(entry.mDataByteSize))
        }
    }
}

/// A stateful resampler. Only its owner serial queue may call convert/finish.
final class StreamingPCMConverter {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var completed = false

    init(inputFormat: AVAudioFormat) throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: output) else {
            throw StreamingRecorderError.conversionFailed
        }
        self.inputFormat = inputFormat
        self.outputFormat = output
        self.converter = converter
        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        // Normal priming keeps the initial signal aligned. finish() supplies
        // endOfStream, causing the converter to emit its buffered trailing audio.
        converter.primeMethod = .normal
    }

    func convert(_ captured: CapturedPCM) throws -> [Data] {
        guard !completed else { throw StreamingRecorderError.conversionFailed }
        if captured.frames == 0 { return [] }
        return try run(input: captured, endOfStream: false)
    }

    func finish() throws -> [Data] {
        guard !completed else { return [] }
        let chunks = try run(input: nil, endOfStream: true)
        completed = true
        return chunks
    }

    private func run(input: CapturedPCM?, endOfStream: Bool) throws -> [Data] {
        var cursor: AVAudioFrameCount = 0
        var chunks: [Data] = []
        // A normal tap is 1,024 frames. This bound also catches converter stalls
        // while accommodating unusual hardware buffers and final drain output.
        for _ in 0..<256 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1_024) else {
                throw StreamingRecorderError.conversionFailed
            }
            var inputFailure = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, outStatus in
                guard let input, cursor < input.frames else {
                    outStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                    return nil
                }
                let count = min(AVAudioFrameCount(requested), input.frames - cursor)
                guard count > 0,
                      let slice = AVAudioPCMBuffer(pcmFormat: self.inputFormat, frameCapacity: count) else {
                    inputFailure = true
                    outStatus.pointee = .noDataNow
                    return nil
                }
                slice.frameLength = count
                let destinations = UnsafeMutableAudioBufferListPointer(slice.mutableAudioBufferList)
                let bytesPerFrame = Int(self.inputFormat.streamDescription.pointee.mBytesPerFrame)
                let offset = Int(cursor) * bytesPerFrame
                let byteCount = Int(count) * bytesPerFrame
                guard destinations.count == input.buffers.count, bytesPerFrame > 0 else {
                    inputFailure = true
                    outStatus.pointee = .noDataNow
                    return nil
                }
                for index in destinations.indices {
                    guard let destination = destinations[index].mData,
                          input.buffers[index].count >= offset + byteCount else {
                        inputFailure = true
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    _ = input.buffers[index].withUnsafeBytes { bytes in
                        memcpy(destination, bytes.baseAddress!.advanced(by: offset), byteCount)
                    }
                }
                cursor += count
                outStatus.pointee = .haveData
                return slice
            }
            guard !inputFailure, error == nil, status != .error else {
                throw StreamingRecorderError.conversionFailed
            }
            if output.frameLength > 0 {
                guard let data = output.audioBufferList.pointee.mBuffers.mData else {
                    throw StreamingRecorderError.conversionFailed
                }
                chunks.append(Data(bytes: data, count: Int(output.frameLength) * 2))
            }
            switch status {
            case .haveData: continue
            case .inputRanDry:
                guard !endOfStream, cursor == (input?.frames ?? 0) else {
                    throw StreamingRecorderError.conversionFailed
                }
                return chunks
            case .endOfStream:
                guard endOfStream else { throw StreamingRecorderError.conversionFailed }
                return chunks
            case .error: throw StreamingRecorderError.conversionFailed
            @unknown default: throw StreamingRecorderError.conversionFailed
            }
        }
        throw StreamingRecorderError.conversionFailed
    }
}
