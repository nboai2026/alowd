import Foundation
import Testing
@testable import AlowdCore

/// The live-partials seam on DictationSessionRunner: start begins it, stop and
/// cancel end it, partials reach the callback, and the live path can never
/// affect the dictation result.
@MainActor
struct DictationSessionRunnerLiveTests {
    @Test func startRecordingStartsLiveTranscriptionAndForwardsPartials() throws {
        let live = FakeLiveTranscriptionController()
        let runner = makeRunner(live: live)
        var partials: [String] = []
        runner.onPartialTranscript = { partials.append($0) }

        _ = try runner.startRecording()
        #expect(live.startCount == 1, "startRecording must start the live transcription path")

        live.emit("hello")
        live.emit("hello world")
        #expect(partials == ["hello", "hello world"], "Partials must be forwarded to onPartialTranscript while recording")
    }

    @Test func stopDictationStopsLiveTranscriptionBeforeBatchTranscription() async throws {
        let live = FakeLiveTranscriptionController()
        let runner = makeRunner(live: live)
        var partials: [String] = []
        runner.onPartialTranscript = { partials.append($0) }

        _ = try runner.startRecording()
        let finalText = try await runner.stopDictation(selectedMode: .raw)

        #expect(live.stopCount >= 1, "stopDictation must stop the live path")
        #expect(finalText == "batch result", "The batch pipeline stays the source of truth for the final text")

        // A straggler partial after stop must be dropped by the runner.
        live.emit("stale partial")
        #expect(partials.isEmpty, "Partials emitted after recording ended must be ignored")
    }

    @Test func cancelRecordingStopsLiveTranscription() throws {
        let live = FakeLiveTranscriptionController()
        let runner = makeRunner(live: live)

        _ = try runner.startRecording()
        runner.cancelRecording()

        #expect(live.stopCount >= 1, "cancelRecording must stop the live path")
    }

    @Test func dictationSucceedsWithoutAnyLiveTranscriber() async throws {
        let runner = makeRunner(live: nil)
        _ = try runner.startRecording()
        let finalText = try await runner.stopDictation(selectedMode: .raw)
        #expect(finalText == "batch result", "The live seam is optional; dictation must work without it")
    }

    @Test func cachedLiveSampleTranscriberIsNilBeforeAnyPipelineExists() throws {
        let runner = makeRunner(live: nil)
        #expect(runner.cachedLiveSampleTranscriber == nil, "No cached engine exists before the first dictation")
    }

    /// Regression: the cache stayed empty until the first `stopDictation`, so
    /// the live path loaded a WhisperKit of its own for the first recording of
    /// every launch — two copies of a multi-gigabyte model resident at once,
    /// with separate decode gates, for the rest of the process.
    @Test func prepareLiveSampleTranscriberBuildsTheSameEngineTheDictationUses() async throws {
        let (runner, factory) = makeCountingRunner()

        let prepared = try await runner.prepareLiveSampleTranscriber()
        #expect(prepared != nil, "Preparing must hand back the shared engine, not nil")
        #expect(factory.callCount == 1, "Preparing builds the pipeline exactly once")
        #expect(runner.cachedLiveSampleTranscriber != nil, "Preparing must populate the cache")

        _ = try runner.startRecording()
        _ = try await runner.stopDictation(selectedMode: .raw)

        #expect(factory.callCount == 1, "The dictation must reuse the prepared pipeline, not build a second one")
        #expect(
            prepared as AnyObject === runner.cachedLiveSampleTranscriber as AnyObject,
            "Live partials and the final decode must run on one engine instance"
        )
    }

    @Test func preparingTwiceReusesTheCachedPipeline() async throws {
        let (runner, factory) = makeCountingRunner()
        let first = try await runner.prepareLiveSampleTranscriber()
        let second = try await runner.prepareLiveSampleTranscriber()
        #expect(factory.callCount == 1, "A second prepare must hit the cache")
        #expect(first as AnyObject === second as AnyObject)
    }

    // MARK: - Streaming

    @Test func aStreamedTranscriptIsUsedWithoutDecodingTheFileAgain() async throws {
        let live = FakeLiveTranscriptionController()
        live.streamed = StreamedTranscript(text: "streamed result", language: "en")
        let engine = CountingEngine(text: "batch result")
        let runner = makeRunner(live: live, engine: engine)

        _ = try runner.startRecording()
        let finalText = try await runner.stopDictation(selectedMode: .raw)

        #expect(finalText == "streamed result")
        #expect(engine.callCount == 0, "Re-decoding the whole recording after stop is the wait this removes")
        #expect(runner.lastDetectedLanguage == "en")
    }

    @Test func anUntrustworthyStreamFallsBackToTheRecordedFile() async throws {
        let live = FakeLiveTranscriptionController()
        live.streamed = nil
        let engine = CountingEngine(text: "batch result")
        let runner = makeRunner(live: live, engine: engine)

        _ = try runner.startRecording()
        let finalText = try await runner.stopDictation(selectedMode: .raw)

        #expect(finalText == "batch result")
        #expect(engine.callCount == 1)
        #expect(live.finishCount == 1)
    }

    @Test func finalSentencesAreRewrittenWhileTheUserIsStillTalking() async throws {
        let first = "This first sentence is comfortably long enough to stand alone."
        let second = "And the second one is long enough to stand on its own too."
        let live = FakeLiveTranscriptionController()
        live.streamed = StreamedTranscript(text: "\(first) \(second)", language: nil)
        let processor = RecordingProcessor()
        let runner = makeRunner(live: live, processor: processor, rewritesIncrementally: true)
        _ = try await runner.prepareLiveSampleTranscriber()

        _ = try runner.startRecording()
        live.emit(update: StreamingTranscriptUpdate(
            confirmedText: "\(first) \(second)",
            text: "\(first) \(second)",
            endsInSilence: false,
            language: nil
        ))
        for _ in 0..<200 where processor.inputs.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(processor.inputs == [first], "Only closed chunks are rewritten before a pause")

        let finalText = try await runner.stopDictation(selectedMode: .myVoiceCasual)

        #expect(finalText == "[\(first)] [\(second)]")
        #expect(processor.inputs == [first, second], "Stop only pays for the chunk not yet rewritten")
        let timing = try #require(runner.lastTiming)
        #expect(timing.stopToInsertSeconds != nil, "The wait after stop must be measured")
    }

    @Test func historyIsStillWrittenWhenThePasteFails() async throws {
        let history = RecordingHistoryWriter()
        let runner = makeRunner(live: nil, history: history, inserter: FailingInserter())

        _ = try runner.startRecording()
        await #expect(throws: TextInserterError.self) {
            try await runner.stopDictation(selectedMode: .raw)
        }

        #expect(history.records.map(\.finalText) == ["batch result"], "A failed paste must never lose the transcript")
    }

    // MARK: - Fixtures

    private func makeRunner(
        live: FakeLiveTranscriptionController?,
        engine: TranscriptionEngine = StubTranscriptionEngine(text: "batch result"),
        processor: PostProcessor = RuleBasedPostProcessor(),
        rewritesIncrementally: Bool = false,
        history: TranscriptHistoryWriting = LiveFakeHistoryWriter(),
        inserter: TextInserter = LiveFakeTextInserter()
    ) -> DictationSessionRunner {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alowd-live-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runner = DictationSessionRunner(
            recorder: LiveFakeRecorder(audioFile: root.appendingPathComponent("dictation.wav")),
            profile: LiveFakeProfileReader(),
            history: history,
            pipelineFactory: { _ in
                DictationPipeline(
                    engine: engine,
                    processor: processor,
                    inserter: inserter,
                    rewritesIncrementally: rewritesIncrementally
                )
            }
        )
        runner.liveTranscription = live
        return runner
    }

    /// A runner whose engine also decodes live samples, so the shared-instance
    /// behaviour is observable, and whose factory counts how often it is asked
    /// to build a pipeline.
    private func makeCountingRunner() -> (DictationSessionRunner, CountingPipelineFactory) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alowd-live-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factory = CountingPipelineFactory()
        let runner = DictationSessionRunner(
            recorder: LiveFakeRecorder(audioFile: root.appendingPathComponent("dictation.wav")),
            profile: LiveFakeProfileReader(),
            history: LiveFakeHistoryWriter(),
            pipelineFactory: { _ in factory.make() }
        )
        return (runner, factory)
    }
}

/// Engine that satisfies both the batch and the live-sample seams, so a test
/// can tell whether the two paths share one instance.
private final class LiveCapableStubEngine: TranscriptionEngine, LiveSampleTranscribing, @unchecked Sendable {
    func transcribe(audioFile: URL) async throws -> TranscriptResult {
        TranscriptResult(text: "batch result", confidence: 1.0, language: nil)
    }

    func transcribeSegments(
        _ samples: [Float],
        languageHint: String?,
        shouldContinue: @escaping @Sendable () -> Bool
    ) async throws -> SegmentedTranscript {
        SegmentedTranscript(segments: [TimedSegment(text: "partial", startSample: 0, endSample: samples.count)])
    }
}

private final class CountingPipelineFactory: @unchecked Sendable {
    private(set) var callCount = 0
    private var engine: LiveCapableStubEngine?

    /// Returns a pipeline over one engine instance, mirroring how the real
    /// factory hands back a freshly loaded WhisperKit per call.
    func make() -> DictationPipeline {
        callCount += 1
        let engine = LiveCapableStubEngine()
        self.engine = engine
        return DictationPipeline(
            engine: engine,
            processor: RuleBasedPostProcessor(),
            inserter: LiveFakeTextInserter()
        )
    }
}

// MARK: - Fakes

@MainActor
final class FakeLiveTranscriptionController: LiveTranscriptionControlling {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var finishCount = 0
    /// What `finish` hands back; nil sends the runner to the batch path.
    var streamed: StreamedTranscript?
    private var onPartial: (@MainActor @Sendable (String) -> Void)?
    private var onUpdate: (@MainActor @Sendable (StreamingTranscriptUpdate) -> Void)?

    func start(
        onPartial: @escaping @MainActor @Sendable (String) -> Void,
        onUpdate: @escaping @MainActor @Sendable (StreamingTranscriptUpdate) -> Void
    ) {
        startCount += 1
        self.onPartial = onPartial
        self.onUpdate = onUpdate
    }

    func finish() async -> StreamedTranscript? {
        finishCount += 1
        return streamed
    }

    func stop() {
        stopCount += 1
    }

    /// Simulates the decode loop delivering a partial. Deliberately left
    /// wired after stop() so tests can prove the runner drops stragglers.
    func emit(_ partial: String) {
        onPartial?(partial)
    }

    func emit(update: StreamingTranscriptUpdate) {
        onUpdate?(update)
    }
}

private final class LiveFakeRecorder: TemporaryAudioRecorder, @unchecked Sendable {
    private let audioFile: URL
    private(set) var isRecording = false

    init(audioFile: URL) {
        self.audioFile = audioFile
    }

    func beginTemporaryRecording() throws -> URL {
        isRecording = true
        FileManager.default.createFile(atPath: audioFile.path, contents: Data())
        return audioFile
    }

    func finishTemporaryRecording() throws -> URL {
        isRecording = false
        return audioFile
    }

    func discardTemporaryRecording() throws {
        isRecording = false
    }
}

private final class LiveFakeProfileReader: ProfileReading, @unchecked Sendable {
    func bootstrap() throws {}
    func loadSettings() throws -> AppSettings { .default }
    func loadDictionary() throws -> [DictionaryTerm] { [] }
    func loadSnippets() throws -> [Snippet] { [] }
}

private final class LiveFakeHistoryWriter: TranscriptHistoryWriting, @unchecked Sendable {
    func append(_ record: TranscriptRecord) throws {}
}

private final class LiveFakeTextInserter: TextInserter, @unchecked Sendable {
    func insert(_ text: String) throws {}
}

private final class CountingEngine: TranscriptionEngine, @unchecked Sendable {
    private let text: String
    private(set) var callCount = 0

    init(text: String) {
        self.text = text
    }

    func transcribe(audioFile: URL) async throws -> TranscriptResult {
        callCount += 1
        return TranscriptResult(text: text, confidence: 1.0)
    }
}

private final class RecordingHistoryWriter: TranscriptHistoryWriting, @unchecked Sendable {
    private(set) var records: [TranscriptRecord] = []
    func append(_ record: TranscriptRecord) throws { records.append(record) }
}

private final class FailingInserter: TextInserter, @unchecked Sendable {
    func insert(_ text: String) throws { throw TextInserterError.accessibilityNotGranted }
}
