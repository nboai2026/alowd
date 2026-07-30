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

/// Thread-safe accumulator for live samples, capped to a trailing window so
/// periodic partial transcription stays bounded on long dictations.
public final class LiveSampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var appendedTotal = 0
    private let maxSamples: Int

    /// - Parameter maxSamples: trailing window size; defaults to 10s at 16kHz.
    ///   The window is re-decoded on every tick, so a longer one mostly buys
    ///   redundant work that competes with the final transcription.
    public init(maxSamples: Int = 16_000 * 10) {
        self.maxSamples = maxSamples
    }

    public func append(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        appendedTotal += chunk.count
        samples.append(contentsOf: chunk)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        lock.unlock()
    }

    /// Returns the trailing window plus a monotonic count of every sample ever
    /// appended, so callers can tell whether new audio arrived since last time.
    public func snapshot() -> (samples: [Float], appendedTotal: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (samples, appendedTotal)
    }

    public func reset() {
        lock.lock()
        samples.removeAll()
        appendedTotal = 0
        lock.unlock()
    }
}
