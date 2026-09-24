import Foundation
import AVFoundation
#if os(macOS)
import AppKit
#endif

public enum DictationSessionRunnerError: Error, LocalizedError, Equatable {
    case notRecording
    case sessionAlreadyActive
    case recordingTooShort

    public var errorDescription: String? {
        switch self {
        case .notRecording:
            "No active Alowd recording to stop."
        case .sessionAlreadyActive:
            "An Alowd dictation session is already running."
        case .recordingTooShort:
            "That recording was too short to transcribe."
        }
    }
}

public typealias DictationPipelineFactory = @Sendable (AppSettings) async throws -> DictationPipeline

@MainActor
public final class DictationSessionRunner {
    /// Single source of truth for the dictation lifecycle. UI state derives from this.
    public enum State: Equatable, Sendable {
        case idle
        case recording
        case transcribing
    }

    /// Settings that require rebuilding the transcription pipeline when they change.
    private struct PipelineCacheKey: Equatable {
        let profileDirectory: URL
        let language: String?
        let translateToEnglish: Bool
        let modelVariant: String
        let enableOllamaRewrite: Bool
        let ollamaBaseURL: URL
        let ollamaModel: String

        init(settings: AppSettings) {
            self.profileDirectory = settings.profileDirectory
            self.language = settings.language
            self.translateToEnglish = settings.translateToEnglish
            self.modelVariant = settings.modelVariant
            self.enableOllamaRewrite = settings.enableOllamaRewrite
            self.ollamaBaseURL = settings.ollamaBaseURL
            self.ollamaModel = settings.ollamaModel
        }
    }

    private let recorder: TemporaryAudioRecorder
    private let profile: ProfileReading
    private let history: TranscriptHistoryWriting
    private let pipelineFactory: DictationPipelineFactory
    private let now: () -> Date
    private var cachedPipeline: (key: PipelineCacheKey, pipeline: DictationPipeline)?
    /// The build currently in progress, so concurrent callers join it instead
    /// of starting a second one. See `makePipeline`.
    private var pipelineBuild: (key: PipelineCacheKey, task: Task<DictationPipeline, Error>)?
    private var recordingStartedAt: Date?
    /// What this recording will be rewritten with, loaded at start so chunks
    /// can be rewritten while the user is still talking.
    private var sessionRewriteInputs: RewriteInputs?
    /// This session's rewriter, reused at stop when nothing it depends on changed.
    private var sessionRewriter: (inputs: RewriteInputs, language: String?, pipeline: DictationPipeline, rewriter: IncrementalRewriter)?
    /// The newest streaming progress, so stop can start on it immediately.
    private var latestUpdate: StreamingTranscriptUpdate?
    public private(set) var state: State = .idle
    /// Stage timings from the most recent completed dictation.
    public private(set) var lastTiming: DictationTiming?
    /// Language the engine decoded the last dictation with, when it reported
    /// one. Shown to the user so a wrong auto-detect is obvious.
    public private(set) var lastDetectedLanguage: String?

    /// Recordings shorter than this are discarded rather than transcribed: a
    /// stray tap (especially in push-to-talk) otherwise yields a header-only
    /// WAV that the engine rejects with an opaque low-level error. Zero
    /// disables the guard; the app sets the threshold it wants.
    public var minimumRecordingDuration: TimeInterval = 0

    /// Streams the recording through the engine while the user speaks, so
    /// stop only has the last moment left to transcribe. Optional: without it,
    /// or whenever it has nothing trustworthy, the recorded file is decoded.
    public var liveTranscription: LiveTranscriptionControlling?
    /// Receives partial transcript strings while recording.
    public var onPartialTranscript: ((String) -> Void)?

    /// The cached pipeline's engine when it supports live sample decoding, so
    /// the live path can reuse the already-loaded WhisperKit instance.
    public var cachedLiveSampleTranscriber: (any LiveSampleTranscribing)? {
        cachedPipeline?.pipeline.engine as? LiveSampleTranscribing
    }

    /// Builds and caches the pipeline before a dictation finishes, so the
    /// live-partials path can share its engine.
    ///
    /// Without this the cache is empty until the first `stopDictation`, so the
    /// first recording of every launch made the live path load a second
    /// WhisperKit — a second copy of a multi-gigabyte model, with its own
    /// DecodeGate (so the two instances never serialize against each other) and
    /// its own detected-language memory, resident for the rest of the process.
    public func prepareLiveSampleTranscriber() async throws -> (any LiveSampleTranscribing)? {
        let settings = try profile.loadSettings()
        let pipeline = try await makePipeline(settings: settings)
        return pipeline.engine as? LiveSampleTranscribing
    }

    public init(
        recorder: TemporaryAudioRecorder,
        profile: ProfileReading,
        history: TranscriptHistoryWriting,
        pipelineFactory: @escaping DictationPipelineFactory,
        now: @escaping () -> Date = Date.init
    ) {
        self.recorder = recorder
        self.profile = profile
        self.history = history
        self.pipelineFactory = pipelineFactory
        self.now = now
    }

    @discardableResult
    public func startRecording() throws -> URL {
        guard state == .idle else { throw DictationSessionRunnerError.sessionAlreadyActive }
        try profile.bootstrap()
        let audioFile = try recorder.beginTemporaryRecording()
        state = .recording
        recordingStartedAt = now()
        sessionRewriter = nil
        latestUpdate = nil
        sessionRewriteInputs = try? RewriteInputs(
            mode: profile.loadSettings().defaultMode,
            dictionary: profile.loadDictionary(),
            snippets: profile.loadSnippets()
        )
        liveTranscription?.start(
            onPartial: { [weak self] partial in
                guard let self, self.state == .recording else { return }
                self.onPartialTranscript?(partial)
            },
            onUpdate: { [weak self] update in
                guard let self, self.state == .recording else { return }
                self.prefetchRewrites(for: update)
            }
        )
        return audioFile
    }

    /// Starts rewriting the parts of the transcript that are already final,
    /// so that stopping leaves only the last sentence for the model. When the
    /// speaker has paused, the unfinished last chunk is rewritten too, on the
    /// bet that they are about to stop; if they carry on instead, it is
    /// cancelled at stop.
    private func prefetchRewrites(for update: StreamingTranscriptUpdate) {
        latestUpdate = update
        guard let inputs = sessionRewriteInputs,
              let rewriter = rewriter(for: inputs, language: update.language) else { return }
        let chunks = update.endsInSilence
            ? RewriteChunker.chunks(update.text)
            : RewriteChunker.closedChunks(update.confirmedText)
        guard !chunks.isEmpty else { return }
        Task { await rewriter.prefetch(chunks, speculative: update.endsInSilence) }
    }

    /// At stop, the sentences the latest decode already finished will almost
    /// always survive the final one unchanged, so their rewrites can overlap
    /// the tail decode instead of waiting behind it. After a pause the latest
    /// text is the whole transcript, and its guessed last chunk is kept.
    private func prefetchRewritesAtStop() {
        guard let update = latestUpdate,
              let inputs = sessionRewriteInputs,
              let rewriter = rewriter(for: inputs, language: update.language) else { return }
        let chunks = update.endsInSilence
            ? RewriteChunker.chunks(update.text)
            : RewriteChunker.closedChunks(update.text)
        guard !chunks.isEmpty else { return }
        Task { await rewriter.prefetch(chunks, speculative: update.endsInSilence) }
    }

    private func rewriter(for inputs: RewriteInputs, language: String?) -> IncrementalRewriter? {
        guard inputs.mode != .raw,
              let pipeline = cachedPipeline?.pipeline,
              pipeline.rewritesIncrementally else { return nil }
        if let sessionRewriter,
           sessionRewriter.inputs == inputs,
           sessionRewriter.language == language,
           sessionRewriter.pipeline === pipeline {
            return sessionRewriter.rewriter
        }
        let rewriter = IncrementalRewriter(
            processor: pipeline.processor,
            mode: inputs.mode,
            dictionary: inputs.dictionary,
            snippets: inputs.snippets,
            language: language
        )
        sessionRewriter = (inputs, language, pipeline, rewriter)
        return rewriter
    }

    @discardableResult
    public func stopDictation(selectedMode: WritingMode?) async throws -> String {
        guard state == .recording else { throw DictationSessionRunnerError.notRecording }
        let stoppedAt = Date()
        state = .transcribing
        defer {
            if state == .transcribing {
                state = .idle
            }
        }

        // The recorder released the finished file; the runner now owns it.
        let audioFile: URL
        do {
            audioFile = try recorder.finishTemporaryRecording()
        } catch {
            liveTranscription?.stop()
            throw error
        }
        var shouldDeleteTemporaryAudio = true
        defer {
            if shouldDeleteTemporaryAudio {
                try? FileManager.default.removeItem(at: audioFile)
            }
        }

        if let startedAt = recordingStartedAt,
           now().timeIntervalSince(startedAt) < minimumRecordingDuration {
            recordingStartedAt = nil
            liveTranscription?.stop()
            throw DictationSessionRunnerError.recordingTooShort
        }
        recordingStartedAt = nil

        // Capture has stopped, so streaming now has every sample. Usually it
        // has already transcribed nearly all of them.
        prefetchRewritesAtStop()
        let streamed = await liveTranscription?.finish()
        liveTranscription?.stop()

        let settings = try profile.loadSettings()
        let dictionary = try profile.loadDictionary()
        let snippets = try profile.loadSnippets()
        let mode = selectedMode ?? settings.defaultMode
        let pipeline = try await makePipeline(settings: settings)

        var transcriptionAudioFile = audioFile
        var retainedAudioURL: URL?
        if settings.retainRawAudio {
            do {
                let audioDirectory = settings.profileDirectory.appendingPathComponent("audio", isDirectory: true)
                try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
                let destination = audioDirectory.appendingPathComponent(audioFile.lastPathComponent)
                try FileManager.default.moveItem(at: audioFile, to: destination)
                transcriptionAudioFile = destination
                retainedAudioURL = destination
                shouldDeleteTemporaryAudio = false
            } catch {
                // Retention is best effort; keep dictating from the temporary file.
            }
        }

        let audioDuration = Self.audioDuration(of: transcriptionAudioFile)

        // Streaming is the fast path; the recorded file is the fallback when
        // streaming had nothing trustworthy (engine still loading, a failed
        // tail decode, a recording longer than the live buffer).
        try Task.checkCancellation()
        let transcribeStart = Date()
        let transcript: TranscriptResult
        if let streamed {
            transcript = TranscriptResult(text: streamed.text, confidence: 1.0, language: streamed.language)
        } else {
            transcript = try await pipeline.engine.transcribe(audioFile: transcriptionAudioFile)
        }
        try Task.checkCancellation()
        let processStart = Date()
        let inputs = RewriteInputs(mode: mode, dictionary: dictionary, snippets: snippets)
        let finalText = try await pipeline.process(
            transcript,
            mode: mode,
            dictionary: dictionary,
            snippets: snippets,
            rewriter: rewriter(for: inputs, language: transcript.language)
        )
        let timing = DictationTiming(
            transcribeSeconds: processStart.timeIntervalSince(transcribeStart),
            postProcessSeconds: Date().timeIntervalSince(processStart)
        )
        lastTiming = timing
        lastDetectedLanguage = transcript.language

        // A cancelled dictation is discarded entirely — the user asked for it
        // to be thrown away, so it must not linger in history either.
        try Task.checkCancellation()

        var record = TranscriptRecord(
            mode: mode,
            rawText: transcript.text,
            finalText: finalText,
            appBundleIdentifier: frontmostAppBundleIdentifier(),
            retainedAudioPath: retainedAudioURL?.path,
            audioDurationSeconds: audioDuration
        )
        // History is written after pasting, since rewriting the whole history
        // file is not something the user should wait for. It is still written
        // when the paste fails, so the transcript is never lost; persistence
        // itself stays best effort.
        do {
            try pipeline.insert(finalText)
        } catch {
            try? history.append(record)
            throw error
        }
        let stopToInsert = Date().timeIntervalSince(stoppedAt)
        lastTiming = timing.withStopToInsert(stopToInsert)
        record.stopToInsertSeconds = stopToInsert
        try? history.append(record)
        return finalText
    }

    /// Reuses the cached pipeline (and its loaded WhisperKit engine) until a
    /// setting that affects the pipeline changes.
    ///
    /// Callers that arrive while a build is still running join that build
    /// rather than starting their own. Checking only `cachedPipeline` was not
    /// enough: the cache is written after the `await`, and this method is
    /// reentrant, so `stopDictation` asking for the pipeline while the
    /// live-partials path was still loading saw an empty cache and started a
    /// second load of the same model. Two concurrent CoreML loads each trigger
    /// the on-device ANE compile of a multi-gigabyte encoder, race for the same
    /// cache slot, and the loser's work is orphaned — minutes of compilation
    /// and gigabytes of writes for a model that was already being loaded.
    private func makePipeline(settings: AppSettings) async throws -> DictationPipeline {
        let key = PipelineCacheKey(settings: settings)
        if let cachedPipeline, cachedPipeline.key == key {
            return cachedPipeline.pipeline
        }
        if let pipelineBuild, pipelineBuild.key == key {
            return try await pipelineBuild.task.value
        }

        let factory = pipelineFactory
        // Unstructured on purpose: whoever started the build may be cancelled
        // (the live-partials task is, on every stop), and the other callers
        // still need the model that is already loading.
        let build = Task { @MainActor [weak self] in
            let pipeline = try await factory(settings)
            self?.cachedPipeline = (key, pipeline)
            return pipeline
        }
        pipelineBuild = (key, build)
        defer {
            if pipelineBuild?.key == key {
                pipelineBuild = nil
            }
        }
        return try await build.value
    }

    /// Best-effort audio length for history stats (WPM); nil when the file is
    /// missing or unreadable (e.g. fakes in tests).
    private static func audioDuration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.fileFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(file.length) / sampleRate
    }

    private func frontmostAppBundleIdentifier() -> String? {
        #if os(macOS)
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        #else
        nil
        #endif
    }

    public func cancelRecording() {
        liveTranscription?.stop()
        sessionRewriter = nil
        recordingStartedAt = nil
        state = .idle
        try? recorder.discardTemporaryRecording()
    }
}

/// Everything besides the text that decides what a rewrite produces.
private struct RewriteInputs: Equatable {
    let mode: WritingMode
    let dictionary: [DictionaryTerm]
    let snippets: [Snippet]
}
