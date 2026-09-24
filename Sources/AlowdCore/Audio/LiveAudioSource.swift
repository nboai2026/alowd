import Foundation

/// An audio capture that, in addition to recording, can hand its live 16kHz
/// mono Float32 samples to one consumer and broadcast input levels (RMS) for
/// a waveform/level indicator. The single capture stays the source of truth:
/// live consumers observe the same samples that land in the WAV file.
public protocol LiveAudioSource: AnyObject, Sendable {
    /// Registers the single live sample consumer (16kHz mono Float32 chunks).
    /// Pass nil to clear. Called from the audio render thread.
    func setLiveSampleConsumer(_ consumer: (@Sendable ([Float]) -> Void)?)

    /// A stream of RMS input levels (one value per captured buffer, 0...~1).
    /// Each call returns an independent stream; streams finish when the
    /// recording stops or is discarded.
    func inputLevels() -> AsyncStream<Float>
}

/// Computes display levels from raw samples.
public enum AudioLevelMeter {
    /// Root mean square of the samples; 0 for an empty buffer.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }
}

/// Thread-safe fan-out of input level values to any number of AsyncStreams.
public final class InputLevelBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Float>.Continuation] = [:]

    public init() {}

    public func stream() -> AsyncStream<Float> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
        }
    }

    public func yield(_ level: Float) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(level)
        }
    }

    /// Finishes every subscriber stream (recording ended).
    public func finish() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in targets {
            continuation.finish()
        }
    }
}

/// Thread-safe store of everything captured in one recording, which the
/// streaming transcriber decodes from as it arrives.
///
/// Holds the whole recording rather than a trailing window: streaming decodes
/// start wherever the last confirmed segment ended, which can be any distance
/// back. Also keeps one loudness value per 30 ms frame, so "is this stretch
/// silence?" is a cheap question rather than a pass over the raw samples.
public final class LiveSampleBuffer: @unchecked Sendable {
    public static let frameLength = 480

    private let lock = NSLock()
    private var samples: [Float] = []
    private var frameLevels: [Float] = []
    private var overflowed = false
    private let maxSamples: Int

    /// - Parameter maxSamples: recordings longer than this stop accumulating
    ///   and report `overflowed`, so the caller can fall back to decoding the
    ///   WAV. Defaults to 15 minutes at 16kHz (~58 MB).
    public init(maxSamples: Int = 16_000 * 60 * 15) {
        self.maxSamples = maxSamples
    }

    public func append(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !overflowed else { return }
        guard samples.count + chunk.count <= maxSamples else {
            overflowed = true
            return
        }
        samples.append(contentsOf: chunk)
        // Only whole frames get a level; a partial last frame waits for more.
        while (frameLevels.count + 1) * Self.frameLength <= samples.count {
            let start = frameLevels.count * Self.frameLength
            frameLevels.append(AudioLevelMeter.rms(Array(samples[start..<start + Self.frameLength])))
        }
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    /// True once the recording outgrew the buffer; its contents are then
    /// incomplete and must not be used as the transcript's source.
    public var hasOverflowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflowed
    }

    public func samples(from start: Int, to end: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let end = min(end, samples.count)
        guard start < end else { return [] }
        return Array(samples[max(0, start)..<end])
    }

    /// Whether `start..<end` holds no speech, judged against this
    /// recording's own levels so a quiet voice and a hot mic both work.
    ///
    /// A frame is speech when it is louder than `relativeThreshold` of the
    /// recording's speaking level (90th-percentile frame) and clearly above
    /// its noise floor (2nd percentile). There is deliberately no absolute
    /// floor: a quiet voice on a quiet mic can sit below any fixed level and
    /// would be thrown away as silence. The threshold is also capped well
    /// below the speaking level: in speech with barely a pause the "noise
    /// floor" is itself speech, and uncapped it would silence everything.
    public func isSilent(from start: Int, to end: Int, relativeThreshold: Float = 0.15) -> Bool {
        // Only frames wholly inside the range: the frame straddling `start`
        // usually holds the tail of the last word.
        let firstFrame = (max(0, start) + Self.frameLength - 1) / Self.frameLength
        lock.lock()
        let lastFrame = min(frameLevels.count, end / Self.frameLength)
        guard firstFrame < lastFrame else {
            lock.unlock()
            return true
        }
        let levels = frameLevels
        lock.unlock()
        // Sorted outside the lock: the capture thread appends under it.
        let sorted = levels.sorted()
        let noiseFloor = sorted[sorted.count / 50]
        let speakingLevel = sorted[min(sorted.count - 1, sorted.count * 9 / 10)]
        let threshold = min(max(noiseFloor * 3, speakingLevel * relativeThreshold), speakingLevel * 0.25)
        return !levels[firstFrame..<lastFrame].contains { $0 > threshold }
    }

    public func reset() {
        lock.lock()
        samples.removeAll()
        frameLevels.removeAll()
        overflowed = false
        lock.unlock()
    }
}
