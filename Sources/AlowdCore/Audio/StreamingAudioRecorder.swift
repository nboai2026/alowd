import Foundation
#if os(macOS)
@preconcurrency import AVFoundation
import CoreAudio
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
    /// Set instead of `engine` while recording a specific device.
    private var deviceCapture: HALInputCapture?
    private var audioFile: AVAudioFile?
    private var configurationObserver: NSObjectProtocol?
    /// Bumped whenever capture stops, so an engine rebuild that was in flight
    /// can tell its recording has ended and must not leave the mic running.
    private var captureGeneration = 0
    /// Engines are started and replaced here, one at a time, and never on the
    /// thread that delivers the configuration-change notification.
    private let captureQueue = DispatchQueue(label: "app.alowd.streaming-audio-recorder.capture")
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
        let deviceCapture = self.deviceCapture
        let observer = configurationObserver
        self.engine = nil
        self.deviceCapture = nil
        self.audioFile = nil
        configurationObserver = nil
        captureGeneration += 1
        lock.unlock()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        deviceCapture?.stop()
        #endif
        levels.finish()
    }

    #if os(macOS)
    private func startEngine(writingTo url: URL) throws {
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

        // The file is in place before the engine starts, so the first buffer
        // the live consumer sees is also the first one in the WAV.
        lock.lock()
        audioFile = file
        let generation = captureGeneration
        lock.unlock()

        guard captureQueue.sync(execute: { startCapture(generation: generation) }) else {
            lock.lock()
            audioFile = nil
            lock.unlock()
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.failedToStart(url)
        }
    }

    /// Builds a running engine that feeds `handleCapturedBuffer` and makes it
    /// the recorder's engine. False when the input could not be started, or
    /// the recording ended meanwhile. Runs on `captureQueue`.
    private func startCapture(generation: Int) -> Bool {
        // A Bluetooth headset is recorded around rather than through: its
        // microphone would drop playback to call quality. Should the
        // built-in mic fail to open, the headset is still better than nothing.
        if let device = AudioInputDevices.builtInReplacingBluetoothDefault(),
           let started = startDeviceCapture(device, generation: generation) {
            return started
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // A dead input device reports a 0 Hz format; installing a tap on it
        // raises an ObjC exception, so refuse up front.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return false }

        guard let targetFormat = Self.makeTargetFormat(),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { return false }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleCapturedBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        // The engine stops itself whenever its device is reconfigured, and
        // nothing restarts it. Bluetooth headsets do this on every recording:
        // opening their microphone switches them from music to call mode a
        // moment after the engine starts, so without this the capture ends
        // before delivering a single buffer.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self, weak engine] _ in
            guard let self, let engine else { return }
            // Off the notifying thread: tearing an engine down from inside
            // its own notification can deadlock.
            self.captureQueue.async { self.recoverCapture(replacing: engine) }
        }

        engine.prepare()
        var started = (try? engine.start()) != nil

        lock.lock()
        started = started && captureGeneration == generation
        if started {
            self.engine = engine
            configurationObserver = observer
        }
        lock.unlock()

        if !started {
            NotificationCenter.default.removeObserver(observer)
            input.removeTap(onBus: 0)
            engine.stop()
        }
        return started
    }

    /// Records `device` itself, bypassing the system default. Nil when the
    /// device could not be opened, so the caller can fall back to the default
    /// input; otherwise whether it is now the recorder's capture (false when
    /// the recording ended meanwhile). Runs on `captureQueue`.
    private func startDeviceCapture(_ device: AudioDeviceID, generation: Int) -> Bool? {
        guard let capture = HALInputCapture(device: device),
              let targetFormat = Self.makeTargetFormat(),
              let converter = AVAudioConverter(from: capture.format, to: targetFormat) else { return nil }
        guard capture.start({ [weak self] buffer in
            self?.handleCapturedBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }) else {
            capture.stop()
            return nil
        }

        lock.lock()
        let current = captureGeneration == generation
        if current {
            deviceCapture = capture
        }
        lock.unlock()

        if !current {
            capture.stop()
        }
        return current
    }

    /// What every capture is converted to: the WAV's and live feed's format.
    private static func makeTargetFormat() -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    /// Replaces an engine that stopped because its device was reconfigured
    /// (a Bluetooth headset switching modes, headphones plugged in or pulled
    /// out mid-recording), continuing into the same WAV. Runs on `captureQueue`.
    private func recoverCapture(replacing stopped: AVAudioEngine) {
        lock.lock()
        // Already replaced, or the recording ended.
        guard engine === stopped else {
            lock.unlock()
            return
        }
        let observer = configurationObserver
        engine = nil
        configurationObserver = nil
        let generation = captureGeneration
        lock.unlock()

        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        stopped.inputNode.removeTap(onBus: 0)
        stopped.stop()

        // A new engine rather than a restart: the stopped one keeps reporting
        // the format from before the change, and a tap installed with it
        // never fires. The device can still be mid-switch, hence the retries.
        for attempt in 0..<5 {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: 0.2)
            }
            lock.lock()
            let recordingEnded = captureGeneration != generation
            lock.unlock()
            if recordingEnded || startCapture(generation: generation) { return }
        }
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
