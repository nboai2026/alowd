import Foundation

/// A transcription engine that can also decode raw 16kHz mono Float samples,
/// which is what live partial transcription feeds it.
public protocol LiveSampleTranscribing: Sendable {
    func transcribeLiveSamples(_ samples: [Float]) async throws -> String
}

/// Controls the best-effort live partial transcript path. Implementations
/// must never throw and must never let a live failure affect the dictation:
/// partials are display-only, the batch pipeline stays the source of truth.
@MainActor
public protocol LiveTranscriptionControlling: AnyObject {
    /// Starts emitting throttled partial transcripts to `onPartial` (on the
    /// main actor). Safe to call even if a previous run is still active.
    func start(onPartial: @escaping @MainActor @Sendable (String) -> Void)

    /// Stops the live path. Idempotent.
    func stop()
}

/// Real implementation: subscribes to the shared audio capture's live sample
/// feed and periodically transcribes the accumulated trailing window with a
/// LiveSampleTranscribing engine (WhisperKit's AudioStreamTranscriber insists
/// on owning the microphone, so we feed samples to the array-decode API
/// instead — one capture only). Everything is best effort and silent.
@MainActor
public final class LiveTranscriptionController: LiveTranscriptionControlling {
    /// Supplies the decode engine, preferring the dictation pipeline's cached
    /// WhisperKit instance so no second model load is needed once warm.
    public typealias EngineProvider = @MainActor @Sendable () async throws -> any LiveSampleTranscribing

    private let source: any LiveAudioSource
    private let engineProvider: EngineProvider
    private let interval: TimeInterval
    private let minimumSampleCount: Int
    private let buffer = LiveSampleBuffer()
    private var task: Task<Void, Never>?
    /// Bumped on every start/stop so a stale loop can never emit a partial
    /// into a newer session.
    private var generation = 0

    /// - Parameters:
    ///   - interval: throttle between partial decodes (~1/s by default).
    ///   - minimumSampleCount: don't decode before this much audio exists
    ///     (default 0.5s at 16kHz); tiny buffers only produce noise.
    public init(
        source: any LiveAudioSource,
        engineProvider: @escaping EngineProvider,
        interval: TimeInterval = 1.0,
        minimumSampleCount: Int = 8_000
    ) {
        self.source = source
        self.engineProvider = engineProvider
        self.interval = interval
        self.minimumSampleCount = minimumSampleCount
    }

    public func start(onPartial: @escaping @MainActor @Sendable (String) -> Void) {
        stop()
        generation += 1
        let startedGeneration = generation
        buffer.reset()
        let buffer = self.buffer
        source.setLiveSampleConsumer { samples in
            buffer.append(samples)
        }

        let interval = self.interval
        let minimumSampleCount = self.minimumSampleCount
        task = Task { [weak self] in
            // Engine acquisition is the likeliest failure (model missing,
            // still loading): swallow it — live partials just don't appear.
            guard let engineProvider = self?.engineProvider,
                  let engine = try? await engineProvider() else { return }

            var lastDecodedTotal = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled, self.generation == startedGeneration else { return }

                let (samples, appendedTotal) = self.buffer.snapshot()
                guard appendedTotal > lastDecodedTotal, samples.count >= minimumSampleCount else { continue }
                lastDecodedTotal = appendedTotal

                // A single decode failure is silently skipped; the next tick
                // tries again with more audio.
                guard let text = try? await engine.transcribeLiveSamples(samples) else { continue }
                guard !Task.isCancelled, self.generation == startedGeneration else { return }

                let partial = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !partial.isEmpty {
                    onPartial(partial)
                }
            }
        }
    }

    public func stop() {
        generation += 1
        task?.cancel()
        task = nil
        source.setLiveSampleConsumer(nil)
        buffer.reset()
    }
}
