import Foundation
#if os(macOS)
@preconcurrency import AVFoundation
#endif

/// AVAudioEngine-based recorder that keeps the exact TemporaryAudioRecorder
/// contract of AudioRecorder (same 16kHz mono WAV temp file, same errors)
/// while also exposing the live sample feed and input levels. Only one audio
/// capture runs: the tap both writes the WAV and feeds live consumers.
public final class StreamingAudioRecorder: TemporaryAudioRecorder, LiveAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var temporaryAudioFile: URL?
    private var sampleConsumer: (@Sendable ([Float]) -> Void)?
    private let levels = InputLevelBroadcaster()
    private var _isRecording = false

    #if os(macOS)
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    #endif

    public var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRecording
    }

    public init() {}

    // MARK: - LiveAudioSource

    public func setLiveSampleConsumer(_ consumer: (@Sendable ([Float]) -> Void)?) {
        lock.lock()
        sampleConsumer = consumer
        lock.unlock()
    }

    public func inputLevels() -> AsyncStream<Float> {
        levels.stream()
    }

    // MARK: - TemporaryAudioRecorder

    public func beginTemporaryRecording() throws -> URL {
        guard !isRecording else { throw AudioRecorderError.alreadyRecording }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alowd-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        #if os(macOS)
        try startEngine(writingTo: url)
        #else
        FileManager.default.createFile(atPath: url.path, contents: nil)
        #endif

        lock.lock()
        temporaryAudioFile = url
        _isRecording = true
        lock.unlock()
        return url
    }

    public func finishTemporaryRecording() throws -> URL {
        guard isRecording else { throw AudioRecorderError.notRecording }
        lock.lock()
        let finishedAudioFile = temporaryAudioFile
        lock.unlock()
        guard let finishedAudioFile else { throw AudioRecorderError.missingTemporaryAudioFile }

        stopCapture()

        lock.lock()
        _isRecording = false
        // The finished recording now belongs to the caller; clearing the
        // reference means a later cancel/discard can never delete it.
        temporaryAudioFile = nil
        lock.unlock()

        guard FileManager.default.fileExists(atPath: finishedAudioFile.path) else {
            throw AudioRecorderError.missingTemporaryAudioFile
        }
        return finishedAudioFile
    }

    public func discardTemporaryRecording() throws {
        stopCapture()
        lock.lock()
        _isRecording = false
        let file = temporaryAudioFile
        temporaryAudioFile = nil
        lock.unlock()

        guard let file else { return }
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Capture

    private func stopCapture() {
        #if os(macOS)
        lock.lock()
        let engine = self.engine
        self.engine = nil
        self.audioFile = nil
        lock.unlock()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        #endif
        levels.finish()
    }

    #if os(macOS)
    private func startEngine(writingTo url: URL) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // A dead input device reports a 0 Hz format; installing a tap on it
        // raises an ObjC exception, so refuse up front with the same error
        // AudioRecorder used for start failures.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.failedToStart(url)
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.failedToStart(url)
        }

        let fileSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: fileSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AudioRecorderError.failedToStart(url)
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleCapturedBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.failedToStart(url)
        }

        lock.lock()
        self.engine = engine
        self.audioFile = file
        lock.unlock()
    }

    /// Runs on the audio render thread: converts to 16kHz mono, writes the
    /// WAV, and feeds live consumers. All best effort — a conversion or write
    /// hiccup must never crash the capture.
    private func handleCapturedBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        // The input block runs synchronously inside convert(); the box only
        // exists to satisfy strict-concurrency capture rules.
        final class ProvidedFlag: @unchecked Sendable { var value = false }
        let provided = ProvidedFlag()
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if provided.value {
                status.pointee = .noDataNow
                return nil
            }
            provided.value = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, converted.frameLength > 0,
              let channel = converted.floatChannelData?[0] else { return }

        lock.lock()
        let file = audioFile
        let consumer = sampleConsumer
        lock.unlock()

        // Best effort: the temp file check in finish() surfaces total failure.
        try? file?.write(from: converted)

        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
        consumer?(samples)
        levels.yield(AudioLevelMeter.rms(samples))
    }
    #endif
}
