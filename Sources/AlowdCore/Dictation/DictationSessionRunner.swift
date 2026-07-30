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
    private var recordingStartedAt: Date?
    public private(set) var state: State = .idle
    /// Stage timings from the most recent completed dictation.
    public private(set) var lastTiming: DictationTiming?

    /// Recordings shorter than this are discarded rather than transcribed: a
    /// stray tap (especially in push-to-talk) otherwise yields a header-only
    /// WAV that the engine rejects with an opaque low-level error. Zero
    /// disables the guard; the app sets the threshold it wants.
    public var minimumRecordingDuration: TimeInterval = 0

    /// Optional best-effort live partials path. Display-only: its failures
    /// never affect the dictation, and the batch pipeline result below stays
    /// the source of truth for the inserted text.
    public var liveTranscription: LiveTranscriptionControlling?
    /// Receives throttled partial transcript strings while recording.
    public var onPartialTranscript: ((String) -> Void)?

    /// The cached pipeline's engine when it supports live sample decoding, so
    /// the live path can reuse the already-loaded WhisperKit instance.
    public var cachedLiveSampleTranscriber: (any LiveSampleTranscribing)? {
        cachedPipeline?.pipeline.engine as? LiveSampleTranscribing
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
        liveTranscription?.start { [weak self] partial in
            guard let self, self.state == .recording else { return }
            self.onPartialTranscript?(partial)
        }
        return audioFile
    }

    @discardableResult
    public func stopDictation(selectedMode: WritingMode?) async throws -> String {
        guard state == .recording else { throw DictationSessionRunnerError.notRecording }
        liveTranscription?.stop()
        state = .transcribing
        defer {
            if state == .transcribing {
                state = .idle
            }
        }

        // The recorder released the finished file; the runner now owns it.
        let audioFile = try recorder.finishTemporaryRecording()
        var shouldDeleteTemporaryAudio = true
        defer {
            if shouldDeleteTemporaryAudio {
                try? FileManager.default.removeItem(at: audioFile)
            }
        }

        if let startedAt = recordingStartedAt,
           now().timeIntervalSince(startedAt) < minimumRecordingDuration {
            recordingStartedAt = nil
            throw DictationSessionRunnerError.recordingTooShort
        }
        recordingStartedAt = nil

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

        let ((rawText, finalText), timing) = try await pipeline.produceTextTimed(
            audioFile: transcriptionAudioFile,
            mode: mode,
            dictionary: dictionary,
            snippets: snippets
        )
        lastTiming = timing

        // A cancelled dictation is discarded entirely — the user asked for it
        // to be thrown away, so it must not linger in history either.
        try Task.checkCancellation()

        // Record history before insertion so an insertion failure never loses
        // the transcript. History persistence itself is best effort.
        try? history.append(TranscriptRecord(
            mode: mode,
            rawText: rawText,
            finalText: finalText,
            appBundleIdentifier: frontmostAppBundleIdentifier(),
            retainedAudioPath: retainedAudioURL?.path,
            audioDurationSeconds: audioDuration
        ))

        try Task.checkCancellation()
        try pipeline.insert(finalText)
        return finalText
    }

    /// Reuses the cached pipeline (and its loaded WhisperKit engine) until a
    /// setting that affects the pipeline changes.
    private func makePipeline(settings: AppSettings) async throws -> DictationPipeline {
        let key = PipelineCacheKey(settings: settings)
        if let cachedPipeline, cachedPipeline.key == key {
            return cachedPipeline.pipeline
        }
        let pipeline = try await pipelineFactory(settings)
        cachedPipeline = (key, pipeline)
        return pipeline
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
        recordingStartedAt = nil
        state = .idle
        try? recorder.discardTemporaryRecording()
    }
}
