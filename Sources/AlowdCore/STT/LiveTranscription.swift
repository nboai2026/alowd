import Foundation

/// A stretch of decoded speech. Sample positions are relative to the start of
/// the audio that was handed to the decoder.
public struct TimedSegment: Equatable, Sendable {
    public var text: String
    public var startSample: Int
    public var endSample: Int

    public init(text: String, startSample: Int, endSample: Int) {
        self.text = text
        self.startSample = startSample
        self.endSample = endSample
    }
}

/// One decode of live audio.
public struct SegmentedTranscript: Equatable, Sendable {
    public var segments: [TimedSegment]
    /// Language decoded with, when it is known confidently. The session hands
    /// it back on the next decode so auto-detect runs once, not every time.
    public var language: String?

    public init(segments: [TimedSegment], language: String? = nil) {
        self.segments = segments
        self.language = language
    }
}

/// A transcription engine that can decode raw 16kHz mono Float samples into
/// timed segments, which is what streaming transcription feeds it.
public protocol LiveSampleTranscribing: Sendable {
    /// - Parameters:
    ///   - languageHint: the language this session already resolved, if any.
    ///   - shouldContinue: polled while decoding; once it returns false the
    ///     decode is abandoned and throws `CancellationError`.
    func transcribeSegments(
        _ samples: [Float],
        languageHint: String?,
        shouldContinue: @escaping @Sendable () -> Bool
    ) async throws -> SegmentedTranscript
}

/// The transcript streaming had finished by the time recording stopped.
public struct StreamedTranscript: Equatable, Sendable {
    public var text: String
    public var language: String?

    public init(text: String, language: String?) {
        self.text = text
        self.language = language
    }
}

/// Transcript progress while recording, for work that can start before stop.
public struct StreamingTranscriptUpdate: Equatable, Sendable {
    /// Text that can no longer change.
    public var confirmedText: String
    /// Confirmed text plus the latest decode's unconfirmed tail.
    public var text: String
    /// Everything after the latest decode is silence: the speaker has paused,
    /// and `text` is exactly what stopping now would produce.
    public var endsInSilence: Bool
    public var language: String?

    public init(confirmedText: String, text: String, endsInSilence: Bool, language: String?) {
        self.confirmedText = confirmedText
        self.text = text
        self.endsInSilence = endsInSilence
        self.language = language
    }
}

/// Controls streaming transcription for one recording at a time.
@MainActor
public protocol LiveTranscriptionControlling: AnyObject {
    /// Starts decoding the recording as it is captured. `onPartial` receives
    /// display text; `onUpdate` receives the same progress in structured form.
    func start(
        onPartial: @escaping @MainActor @Sendable (String) -> Void,
        onUpdate: @escaping @MainActor @Sendable (StreamingTranscriptUpdate) -> Void
    )

    /// Call once capture has stopped: finishes the transcript and returns it,
    /// or nil when streaming has nothing trustworthy and the caller should
    /// decode the recorded file instead.
    func finish() async -> StreamedTranscript?

    /// Abandons the session. Idempotent.
    func stop()
}

public extension LiveTranscriptionControlling {
    func start(onPartial: @escaping @MainActor @Sendable (String) -> Void) {
        start(onPartial: onPartial, onUpdate: { _ in })
    }

    func finish() async -> StreamedTranscript? { nil }
}

/// Which text of a streaming session is final, and where the audio that still
/// needs decoding begins.
///
/// Every decode covers the audio from `confirmedEnd` to the end of what has
/// been captured. All its segments except the last are confirmed: their text
/// is final and the next decode starts where they ended. It is how Whisper
/// walks through long audio anyway (seek to the last segment's end), done as
/// the audio arrives instead of all at once after stop.
public struct StreamingTranscriptState: Equatable, Sendable {
    /// A segment ending closer than this to the end of the decoded audio is
    /// never confirmed: it may be a word cut off mid-syllable.
    public static let edgeGuardSamples = 8_000

    public private(set) var confirmed: [String] = []
    /// Absolute sample where the next decode starts.
    public private(set) var confirmedEnd = 0
    public private(set) var pending: [String] = []
    /// Absolute sample the latest decode covered up to; 0 before any decode.
    public private(set) var decodedThrough = 0

    public init() {}

    /// - Parameters:
    ///   - start, end: the absolute sample range that was decoded.
    ///   - isFinal: no more audio will arrive, so every segment is confirmed.
    public mutating func apply(_ segments: [TimedSegment], decodedFrom start: Int, through end: Int, isFinal: Bool) {
        var confirmCount = isFinal ? segments.count : max(0, segments.count - 1)
        if !isFinal {
            while confirmCount > 0,
                  start + segments[confirmCount - 1].endSample > end - Self.edgeGuardSamples {
                confirmCount -= 1
            }
        }
        confirmed += segments.prefix(confirmCount).compactMap(Self.cleaned)
        if confirmCount > 0 {
            let lastEnd = start + segments[confirmCount - 1].endSample
            confirmedEnd = min(end, max(confirmedEnd, lastEnd))
        }
        if isFinal {
            confirmedEnd = end
        }
        pending = segments.dropFirst(confirmCount).compactMap(Self.cleaned)
        decodedThrough = end
    }

    /// The speaker finished while the latest decode's audio was the last
    /// thing said, so its unconfirmed segments are final as they stand.
    public mutating func confirmPending(through end: Int) {
        confirmed += pending
        pending = []
        confirmedEnd = end
        decodedThrough = end
    }

    public var confirmedText: String { confirmed.joined(separator: " ") }
    public var text: String { (confirmed + pending).joined(separator: " ") }

    private static func cleaned(_ segment: TimedSegment) -> String? {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Streams the recording through a LiveSampleTranscribing engine while the
/// user speaks, so that stopping leaves only the last moment to decode.
///
/// Decodes run back to back from the last confirmed segment to the newest
/// audio. The display partials are a by-product; the point is that by stop
/// time nearly all of the transcript is already final. On stop:
/// - if the audio after the latest decode is silence (people stop talking,
///   then press the key), that decode is the transcript and nothing is
///   decoded at all;
/// - otherwise only the audio since the last confirmed segment is decoded.
///
/// Everything stays best effort: `finish` returns nil whenever streaming has
/// nothing trustworthy, and the caller decodes the recorded file instead.
@MainActor
public final class LiveTranscriptionController: LiveTranscriptionControlling {
    /// Supplies the decode engine: the dictation pipeline's loaded WhisperKit.
    public typealias EngineProvider = @MainActor @Sendable () async throws -> any LiveSampleTranscribing

    /// How much trailing silence at stop counts as "finished speaking".
    static let finishedSpeakingSamples = 4_800
    /// Stricter than the decode loop's idea of silence. Skipping the tail
    /// decode on a false "silence" drops words that were said, such as a
    /// sentence trailing off, while a false "speech" costs one short decode.
    static let finishedSpeakingThreshold: Float = 0.05

    private let source: any LiveAudioSource
    private let engineProvider: EngineProvider
    private let pollInterval: TimeInterval
    private let minimumNewSamples: Int
    private let minimumSampleCount: Int
    private let buffer: LiveSampleBuffer

    private var task: Task<Void, Never>?
    /// Bumped on every start/stop so a stale loop can never touch a newer session.
    private var generation = 0
    private var state = StreamingTranscriptState()
    private var language: String?
    private var engine: (any LiveSampleTranscribing)?
    /// Absolute sample the in-flight decode covers up to, while one runs.
    private var inFlightThrough: Int?
    /// Absolute sample the latest decode attempt covered, successful or not,
    /// so a failing engine is retried when there is new audio rather than in
    /// a tight loop.
    private var attemptedThrough = 0
    private var abandonInFlight = AbandonFlag()
    private var finishing = false
    private var reportedSilenceAt: Int?
    private var onPartial: (@MainActor @Sendable (String) -> Void)?
    private var onUpdate: (@MainActor @Sendable (StreamingTranscriptUpdate) -> Void)?

    /// - Parameters:
    ///   - pollInterval: how often to look for new audio when there is none.
    ///   - minimumNewSamples: don't re-decode for less new audio than this.
    ///   - minimumSampleCount: don't decode before this much audio exists
    ///     (default 0.5s at 16kHz); tiny buffers only produce noise.
    public init(
        source: any LiveAudioSource,
        engineProvider: @escaping EngineProvider,
        pollInterval: TimeInterval = 0.03,
        minimumNewSamples: Int = 8_000,
        minimumSampleCount: Int = 8_000,
        buffer: LiveSampleBuffer = LiveSampleBuffer()
    ) {
        self.source = source
        self.engineProvider = engineProvider
        self.pollInterval = pollInterval
        self.minimumNewSamples = minimumNewSamples
        self.minimumSampleCount = minimumSampleCount
        self.buffer = buffer
    }

    public func start(
        onPartial: @escaping @MainActor @Sendable (String) -> Void,
        onUpdate: @escaping @MainActor @Sendable (StreamingTranscriptUpdate) -> Void
    ) {
        stop()
        generation += 1
        let session = generation
        state = StreamingTranscriptState()
        language = nil
        engine = nil
        attemptedThrough = 0
        finishing = false
        reportedSilenceAt = nil
        abandonInFlight = AbandonFlag()
        self.onPartial = onPartial
        self.onUpdate = onUpdate
        buffer.reset()
        let buffer = self.buffer
        source.setLiveSampleConsumer { samples in
            buffer.append(samples)
        }

        task = Task { [weak self] in
            // Engine acquisition is the likeliest failure (model missing, still
            // loading): swallow it, and `finish` falls back to the file.
            guard let provider = self?.engineProvider, let engine = try? await provider() else { return }
            guard let self, self.generation == session else { return }
            self.engine = engine
            await self.decodeWhileRecording(with: engine, session: session)
        }
    }

    private func decodeWhileRecording(with engine: any LiveSampleTranscribing, session: Int) async {
        while !Task.isCancelled, generation == session, !finishing {
            let total = buffer.count
            let from = state.confirmedEnd
            let newSinceLastDecode = total - max(state.decodedThrough, attemptedThrough)
            let enoughAudio = total - from >= minimumSampleCount && newSinceLastDecode >= minimumNewSamples
            guard enoughAudio else {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                continue
            }
            // Nothing but silence since the latest decode: decoding it again
            // learns nothing, and Whisper is prone to inventing words in
            // silence. Tell listeners the speaker has paused, once.
            if state.decodedThrough > 0, buffer.isSilent(from: state.decodedThrough, to: total) {
                if reportedSilenceAt != state.decodedThrough {
                    reportedSilenceAt = state.decodedThrough
                    publish(endsInSilence: true)
                }
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                continue
            }

            let samples = buffer.samples(from: from, to: total)
            let abandon = abandonInFlight
            inFlightThrough = total
            attemptedThrough = total
            // A single decode failure is skipped; the next one covers the same
            // audio and more, because nothing was confirmed.
            let result = try? await engine.transcribeSegments(
                samples,
                languageHint: language,
                shouldContinue: { !abandon.isSet }
            )
            inFlightThrough = nil
            guard generation == session, !abandon.isSet else { return }
            guard let result else { continue }
            state.apply(result.segments, decodedFrom: from, through: total, isFinal: false)
            language = language ?? result.language
            publish(endsInSilence: false)
        }
    }

    private func publish(endsInSilence: Bool) {
        let text = state.text
        if !text.isEmpty {
            onPartial?(text)
        }
        onUpdate?(StreamingTranscriptUpdate(
            confirmedText: state.confirmedText,
            text: text,
            endsInSilence: endsInSilence,
            language: language
        ))
    }

    public func finish() async -> StreamedTranscript? {
        guard let task else { return nil }
        let session = generation
        source.setLiveSampleConsumer(nil)
        finishing = true
        let total = buffer.count
        let tailStart = max(0, total - Self.finishedSpeakingSamples)

        // A decode in flight that already covers everything that was said is
        // worth waiting for. One that does not is abandoned: the tail decode
        // below covers its audio plus whatever it missed.
        if let through = inFlightThrough, !buffer.isSilent(from: min(through, tailStart), to: total, relativeThreshold: Self.finishedSpeakingThreshold) {
            abandonInFlight.set()
        }
        await task.value
        // A newer session may have started while this one finished; its task
        // is not ours to clear.
        guard generation == session else { return nil }
        self.task = nil
        guard let engine, !buffer.hasOverflowed else { return nil }

        if state.decodedThrough > 0,
           buffer.isSilent(from: min(state.decodedThrough, tailStart), to: total, relativeThreshold: Self.finishedSpeakingThreshold) {
            state.confirmPending(through: total)
            return StreamedTranscript(text: state.text, language: language)
        }

        let from = state.confirmedEnd
        guard total - from > 0 else {
            return StreamedTranscript(text: state.text, language: language)
        }
        do {
            let result = try await engine.transcribeSegments(
                buffer.samples(from: from, to: total),
                languageHint: language,
                shouldContinue: { true }
            )
            guard generation == session else { return nil }
            state.apply(result.segments, decodedFrom: from, through: total, isFinal: true)
            return StreamedTranscript(text: state.text, language: language ?? result.language)
        } catch {
            return nil
        }
    }

    public func stop() {
        generation += 1
        abandonInFlight.set()
        task?.cancel()
        task = nil
        inFlightThrough = nil
        source.setLiveSampleConsumer(nil)
        buffer.reset()
    }
}

/// Lets `finish` tell a decode running inside WhisperKit to give up.
private final class AbandonFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
