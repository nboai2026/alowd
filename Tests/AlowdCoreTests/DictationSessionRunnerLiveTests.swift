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

    // MARK: - Fixtures

    private func makeRunner(live: FakeLiveTranscriptionController?) -> DictationSessionRunner {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alowd-live-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runner = DictationSessionRunner(
            recorder: LiveFakeRecorder(audioFile: root.appendingPathComponent("dictation.wav")),
            profile: LiveFakeProfileReader(),
            history: LiveFakeHistoryWriter(),
            pipelineFactory: { _ in
                DictationPipeline(
                    engine: StubTranscriptionEngine(text: "batch result"),
                    processor: RuleBasedPostProcessor(),
                    inserter: LiveFakeTextInserter()
                )
            }
        )
        runner.liveTranscription = live
        return runner
    }
}

// MARK: - Fakes

@MainActor
final class FakeLiveTranscriptionController: LiveTranscriptionControlling {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var onPartial: (@MainActor @Sendable (String) -> Void)?

    func start(onPartial: @escaping @MainActor @Sendable (String) -> Void) {
        startCount += 1
        self.onPartial = onPartial
    }

    func stop() {
        stopCount += 1
    }

    /// Simulates the throttled decode loop delivering a partial. Deliberately
    /// left wired after stop() so tests can prove the runner drops stragglers.
    func emit(_ partial: String) {
        onPartial?(partial)
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
