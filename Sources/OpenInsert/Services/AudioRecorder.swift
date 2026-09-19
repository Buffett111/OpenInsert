import AVFoundation
import Darwin
import Foundation

/// Records only after an explicit start, retaining audio in a private temporary directory.
@MainActor
final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private var directory: URL?
    private var recordingURL: URL?
    private var startedAt: Date?
    private var lastDuration: TimeInterval = 0
    private var pendingStart: UUID?

    init() {
        // Best effort on launch; an actionable filesystem error is surfaced if
        // the user subsequently starts a recording.
        _ = try? prepareTemporaryRoot()
    }

    var duration: TimeInterval {
        guard let startedAt else { return lastDuration }
        return min(120, max(0, Date().timeIntervalSince(startedAt)))
    }

    var level: Float {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        return min(1, max(0, pow(10, recorder.averagePower(forChannel: 0) / 20)))
    }

    func start() async throws {
        guard recorder == nil, pendingStart == nil else { throw RecorderError.alreadyRecording }
        let attempt = UUID()
        pendingStart = attempt
        defer { if pendingStart == attempt { pendingStart = nil } }
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .audio)
        default: granted = false
        }
        guard pendingStart == attempt, !Task.isCancelled else { throw CancellationError() }
        guard granted else { throw RecorderError.microphoneDenied }
        let root = try prepareTemporaryRoot()
        let folder = root.appendingPathComponent("recording-\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        directory = folder
        let url = folder.appendingPathComponent("recording.wav")
        recordingURL = url
        do {
            let audio = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false
            ])
            audio.isMeteringEnabled = true
            guard audio.prepareToRecord(), audio.record(forDuration: 120) else {
                throw RecorderError.startFailed
            }
            recorder = audio
            lastDuration = 0
            startedAt = Date()
        } catch {
            cleanup()
            throw error
        }
    }

    func stop() throws -> Data {
        guard let recorder, let recordingURL else { throw RecorderError.notRecording }
        lastDuration = duration
        recorder.stop()
        defer { cleanup() }
        let data = try Data(contentsOf: recordingURL)
        guard data.count > 44,
              String(data: data.prefix(4), encoding: .ascii) == "RIFF",
              String(data: data.dropFirst(8).prefix(4), encoding: .ascii) == "WAVE" else {
            throw RecorderError.emptyRecording
        }
        return data
    }

    func cancel() {
        pendingStart = nil
        lastDuration = duration
        recorder?.stop()
        cleanup()
    }

    private func cleanup() {
        recorder = nil
        recordingURL = nil
        startedAt = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    /// Removes crash leftovers only after their owning process has exited.
    /// Never traverses symlinks or touches temporary directories of other apps.
    private func prepareTemporaryRoot() throws -> URL {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("org.openinsert.OpenInsert", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        let rootAttributes = try manager.attributesOfItem(atPath: root.path)
        guard rootAttributes[.type] as? FileAttributeType == .typeDirectory else {
            throw RecorderError.startFailed
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        for candidate in try manager.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let name = candidate.lastPathComponent
            guard name.hasPrefix("recording-") else { continue }
            let suffix = name.dropFirst("recording-".count)
            guard let separator = suffix.firstIndex(of: "-"),
                  let ownerPID = pid_t(suffix[..<separator]), ownerPID > 0,
                  UUID(uuidString: String(suffix[suffix.index(after: separator)...])) != nil else { continue }
            let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            // EPERM means the process exists; ESRCH is the only deletion case.
            if kill(ownerPID, 0) == -1, errno == ESRCH { try? manager.removeItem(at: candidate) }
        }
        return root
    }

    enum RecorderError: LocalizedError {
        case alreadyRecording, microphoneDenied, startFailed, notRecording, emptyRecording
        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "A recording is already in progress."
            case .microphoneDenied:
                return "Microphone access is required. Enable OpenInsert in System Settings → Privacy & Security → Microphone."
            case .startFailed: return "The microphone could not start. Check that an input device is connected."
            case .notRecording: return "There is no active recording."
            case .emptyRecording: return "The recording contains no usable WAV audio. Please try again."
            }
        }
    }
}
