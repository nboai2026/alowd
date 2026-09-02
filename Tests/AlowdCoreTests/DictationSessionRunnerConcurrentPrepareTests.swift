import Foundation
import Testing
@testable import AlowdCore

/// The real ordering the app produces: `startRecording` kicks the live-partials
/// path into `prepareLiveSampleTranscriber`, which is still loading the model
/// when the user stops and `stopDictation` asks for the same pipeline.
@MainActor
struct DictationSessionRunnerConcurrentPrepareTests {
    @Test func stopDictationDuringAnInFlightPrepareReusesTheSamePipeline() async throws {
        let (runner, factory) = makeSlowRunner(loadDuration: .milliseconds(300))

        // The live path starts loading the engine while recording begins.
        let prepare = Task { try await runner.prepareLiveSampleTranscriber() }
        // Let the prepare get as far as awaiting the factory.
        try await Task.sleep(for: .milliseconds(50))

        _ = try runner.startRecording()
        _ = try await runner.stopDictation(selectedMode: .raw)
        _ = try? await prepare.value

        #expect(
            factory.callCount == 1,
            "A dictation that stops while the live prepare is still loading must reuse that load, not start a second one (built \(factory.callCount) pipelines)"
        )
    }

    private func makeSlowRunner(
        loadDuration: Duration
    ) -> (DictationSessionRunner, SlowCountingFactory) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alowd-concurrent-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factory = SlowCountingFactory(loadDuration: loadDuration)
        let runner = DictationSessionRunner(
            recorder: ConcurrentFakeRecorder(audioFile: root.appendingPathComponent("dictation.wav")),
            profile: ConcurrentFakeProfileReader(),
            history: ConcurrentFakeHistoryWriter(),
            pipelineFactory: { _ in await factory.make() }
        )
        return (runner, factory)
    }
}

/// Counts pipeline builds and takes a realistic amount of time doing it — a
/// 3GB CoreML model load is seconds, not instant.
private final class SlowCountingFactory: @unchecked Sendable {
    private(set) var callCount = 0
    private let loadDuration: Duration

    init(loadDuration: Duration) {
        self.loadDuration = loadDuration
    }

    func make() async -> DictationPipeline {
        callCount += 1
        try? await Task.sleep(for: loadDuration)
        return DictationPipeline(
            engine: ConcurrentStubEngine(),
            processor: RuleBasedPostProcessor(),
            inserter: ConcurrentFakeTextInserter()
        )
    }
}

private final class ConcurrentStubEngine: TranscriptionEngine, LiveSampleTranscribing, @unchecked Sendable {
    func transcribe(audioFile: URL) async throws -> TranscriptResult {
        TranscriptResult(text: "batch result", confidence: 1.0, language: nil)
    }

    func transcribeLiveSamples(_ samples: [Float]) async throws -> String { "partial" }
}

private final class ConcurrentFakeRecorder: TemporaryAudioRecorder, @unchecked Sendable {
    private let audioFile: URL
    private(set) var isRecording = false

    init(audioFile: URL) { self.audioFile = audioFile }

    func beginTemporaryRecording() throws -> URL {
        isRecording = true
        FileManager.default.createFile(atPath: audioFile.path, contents: Data())
        return audioFile
    }

    func finishTemporaryRecording() throws -> URL {
        isRecording = false
        return audioFile
    }

    func discardTemporaryRecording() throws { isRecording = false }
}

private final class ConcurrentFakeProfileReader: ProfileReading, @unchecked Sendable {
    func bootstrap() throws {}
    func loadSettings() throws -> AppSettings { .default }
    func loadDictionary() throws -> [DictionaryTerm] { [] }
    func loadSnippets() throws -> [Snippet] { [] }
}

private final class ConcurrentFakeHistoryWriter: TranscriptHistoryWriting, @unchecked Sendable {
    func append(_ record: TranscriptRecord) throws {}
}

private final class ConcurrentFakeTextInserter: TextInserter, @unchecked Sendable {
    func insert(_ text: String) throws {}
}
