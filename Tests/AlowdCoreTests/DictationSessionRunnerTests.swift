import Foundation
import Testing
@testable import AlowdCore

@MainActor
struct DictationSessionRunnerTests {
    @Test func stopDictationUsesSelectedModeAndDeletesTemporaryAudioByDefault() async throws {
        let root = try temporaryDirectory()
        let profile = FakeProfileReader(
            settings: AppSettings.default,
            dictionary: [DictionaryTerm(phrase: "nbo", replacement: "NBO", source: "test")],
            snippets: []
        )
        let audioFile = root.appendingPathComponent("dictation.wav")
        let recorder = FakeTemporaryAudioRecorder(audioFile: audioFile)
        let inserter = FakeSessionTextInserter()
        let historyWriter = FakeHistoryWriter()
        let runner = DictationSessionRunner(
            recorder: recorder,
            profile: profile,
            history: historyWriter,
            pipelineFactory: { _ in
                DictationPipeline(
                    engine: StubTranscriptionEngine(text: "um hello nbo"),
                    processor: RuleBasedPostProcessor(),
                    inserter: inserter
                )
            }
        )

        _ = try runner.startRecording()
        let finalText = try await runner.stopDictation(selectedMode: .myVoicePro)

        #expect(finalText == "Hello NBO", "Runner must process transcript with selected mode")
        #expect(inserter.insertedTexts == ["Hello NBO"], "Runner must paste final text")
        #expect(!FileManager.default.fileExists(atPath: audioFile.path), "Runner must delete temp audio by default")
        #expect(profile.didBootstrap, "Runner must bootstrap profile before use")
        #expect(historyWriter.appendedRecords.map(\.finalText) == ["Hello NBO"], "Runner must record dictation history")
        #expect(historyWriter.appendedRecords.map(\.rawText) == ["um hello nbo"], "Runner must record raw transcript in history")
    }

    @Test func stopDictationAppendsTranscriptRecordToHistory() async throws {
        let root = try temporaryDirectory()
        let profile = FakeProfileReader(settings: AppSettings.default, dictionary: [], snippets: [])
        let recorder = FakeTemporaryAudioRecorder(audioFile: root.appendingPathComponent("dictation.wav"))
        let historyWriter = FakeHistoryWriter()
        let runner = DictationSessionRunner(
            recorder: recorder,
            profile: profile,
            history: historyWriter,
            pipelineFactory: { _ in
                DictationPipeline(
                    engine: StubTranscriptionEngine(text: "um history entry"),
                    processor: RuleBasedPostProcessor(),
                    inserter: FakeSessionTextInserter()
                )
            }
        )

        _ = try runner.startRecording()
        _ = try await runner.stopDictation(selectedMode: .myVoiceCasual)

        #expect(historyWriter.appendedRecords.count == 1, "Every completed dictation must append exactly one history record")
        let record = try #require(historyWriter.appendedRecords.first)
        #expect(record.mode == .myVoiceCasual, "History must record the selected writing mode")
        #expect(record.rawText == "um history entry", "History must record the raw transcript")
        #expect(record.finalText == "history entry", "History must record the final text")
        #expect(record.retainedAudioPath == nil, "History must not record an audio path when retention is off")
    }

    @Test func stopDictationKeepsTemporaryAudioWhenRetentionEnabled() async throws {
        let root = try temporaryDirectory()
        var settings = AppSettings.default
        settings.retainRawAudio = true
        settings.profileDirectory = root
        let profile = FakeProfileReader(settings: settings, dictionary: [], snippets: [])
        let audioFile = root.appendingPathComponent("dictation.wav")
        let recorder = FakeTemporaryAudioRecorder(audioFile: audioFile)
        let historyWriter = FakeHistoryWriter()
        let runner = DictationSessionRunner(
            recorder: recorder,
            profile: profile,
            history: historyWriter,
            pipelineFactory: { _ in
                DictationPipeline(
                    engine: StubTranscriptionEngine(text: "keep audio"),
                    processor: RuleBasedPostProcessor(),
                    inserter: FakeSessionTextInserter()
                )
            }
        )

        _ = try runner.startRecording()
        _ = try await runner.stopDictation(selectedMode: .raw)

        let retainedFile = root.appendingPathComponent("audio/dictation.wav")
        #expect(FileManager.default.fileExists(atPath: retainedFile.path), "Runner must move retained audio into <profile>/audio")
        #expect(!FileManager.default.fileExists(atPath: audioFile.path), "Runner must not leave the temp audio behind after retention")
        #expect(historyWriter.appendedRecords.map(\.retainedAudioPath) == [retainedFile.path], "Runner must record the retained audio path in history")
    }

    @Test func stopDictationDeletesTemporaryAudioWhenPipelineSetupFails() async throws {
        let profile = FakeProfileReader(settings: AppSettings.default, dictionary: [], snippets: [])
        let audioFile = try temporaryDirectory().appendingPathComponent("dictation.wav")
        let recorder = FakeTemporaryAudioRecorder(audioFile: audioFile)
        let runner = DictationSessionRunner(
            recorder: recorder,
            profile: profile,
            history: FakeHistoryWriter(),
            pipelineFactory: { _ in throw PipelineSetupFailure() }
        )

        _ = try runner.startRecording()
        await #expect(throws: PipelineSetupFailure.self, "Runner must surface pipeline setup failure") {
            _ = try await runner.stopDictation(selectedMode: .raw)
        }

        #expect(!FileManager.default.fileExists(atPath: audioFile.path), "Runner must delete temp audio when local model setup fails")
    }

    @Test func stopDictationRequiresActiveRecording() async throws {
        let runner = DictationSessionRunner(
            recorder: FakeTemporaryAudioRecorder(audioFile: try temporaryDirectory().appendingPathComponent("dictation.wav")),
            profile: FakeProfileReader(settings: AppSettings.default, dictionary: [], snippets: []),
            history: FakeHistoryWriter(),
            pipelineFactory: { _ in
                DictationPipeline(
                    engine: StubTranscriptionEngine(text: ""),
                    processor: RuleBasedPostProcessor(),
                    inserter: FakeSessionTextInserter()
                )
            }
        )

        await #expect(throws: DictationSessionRunnerError.notRecording, "Runner must reject stop when recording has not started") {
            _ = try await runner.stopDictation(selectedMode: .raw)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alowd-runner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct PipelineSetupFailure: Error, Equatable {}

private final class FakeProfileReader: ProfileReading, @unchecked Sendable {
    private let settings: AppSettings
    private let dictionary: [DictionaryTerm]
    private let snippets: [Snippet]
    private(set) var didBootstrap = false

    init(settings: AppSettings, dictionary: [DictionaryTerm], snippets: [Snippet]) {
        self.settings = settings
        self.dictionary = dictionary
        self.snippets = snippets
    }

    func bootstrap() throws {
        didBootstrap = true
    }

    func loadSettings() throws -> AppSettings {
        settings
    }

    func loadDictionary() throws -> [DictionaryTerm] {
        dictionary
    }

    func loadSnippets() throws -> [Snippet] {
        snippets
    }
}

private final class FakeTemporaryAudioRecorder: TemporaryAudioRecorder, @unchecked Sendable {
    private let audioFile: URL
    private(set) var didDiscardTemporaryRecording = false
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
        didDiscardTemporaryRecording = true
    }
}

extension DictationSessionRunnerTests {
    /// A tap of the shortcut must be discarded, not sent to the engine as a
    /// header-only WAV — and the transcript must never reach history.
    @Test func stopDictationRejectsRecordingShorterThanMinimum() async throws {
        let root = try temporaryDirectory()
        let audioFile = root.appendingPathComponent("dictation.wav")
        let inserter = FakeSessionTextInserter()
        let historyWriter = FakeHistoryWriter()
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        let runner = DictationSessionRunner(
            recorder: FakeTemporaryAudioRecorder(audioFile: audioFile),
            profile: FakeProfileReader(settings: AppSettings.default, dictionary: [], snippets: []),
            history: historyWriter,
            pipelineFactory: { _ in
                DictationPipeline(
                    engine: StubTranscriptionEngine(text: "hi"),
                    processor: RuleBasedPostProcessor(),
                    inserter: inserter
                )
            },
            now: { clock }
        )
        runner.minimumRecordingDuration = 0.4

        _ = try runner.startRecording()
        clock.addTimeInterval(0.2)

        await #expect(throws: DictationSessionRunnerError.recordingTooShort) {
            try await runner.stopDictation(selectedMode: nil)
        }
        #expect(inserter.insertedTexts.isEmpty, "A too-short recording must not paste anything")
        #expect(historyWriter.appendedRecords.isEmpty, "A too-short recording must not reach history")
        #expect(runner.state == .idle, "Runner must return to idle after rejecting a short recording")
        #expect(!FileManager.default.fileExists(atPath: audioFile.path), "Short recording audio must be cleaned up")
    }

    @Test func stopDictationAcceptsRecordingAtOrAboveMinimum() async throws {
        let root = try temporaryDirectory()
        let audioFile = root.appendingPathComponent("dictation.wav")
        let inserter = FakeSessionTextInserter()
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        let runner = DictationSessionRunner(
            recorder: FakeTemporaryAudioRecorder(audioFile: audioFile),
            profile: FakeProfileReader(settings: AppSettings.default, dictionary: [], snippets: []),
            history: FakeHistoryWriter(),
            pipelineFactory: { _ in
                DictationPipeline(
                    engine: StubTranscriptionEngine(text: "hello"),
                    processor: RuleBasedPostProcessor(),
                    inserter: inserter
                )
            },
            now: { clock }
        )
        runner.minimumRecordingDuration = 0.4

        _ = try runner.startRecording()
        clock.addTimeInterval(0.4)
        let finalText = try await runner.stopDictation(selectedMode: nil)

        #expect(finalText == "hello", "A long enough recording must transcribe normally")
        #expect(inserter.insertedTexts == ["hello"], "A long enough recording must paste")
    }
}

/// Engine that never finishes on its own, standing in for a slow WhisperKit
/// transcription so a cancel can arrive mid-flight.
private final class HangingTranscriptionEngine: TranscriptionEngine {
    func transcribe(audioFile: URL) async throws -> TranscriptResult {
        try await Task.sleep(for: .seconds(30))
        return TranscriptResult(text: "should never be produced", confidence: 1)
    }
}

@MainActor
struct DictationSessionRunnerCancellationTests {
    @Test func cancellingMidTranscriptionInsertsNothingAndWritesNoHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inserter = FakeSessionTextInserter()
        let historyWriter = FakeHistoryWriter()
        let runner = DictationSessionRunner(
            recorder: FakeTemporaryAudioRecorder(audioFile: root.appendingPathComponent("dictation.wav")),
            profile: FakeProfileReader(settings: AppSettings.default, dictionary: [], snippets: []),
            history: historyWriter,
            pipelineFactory: { _ in
                DictationPipeline(
                    engine: HangingTranscriptionEngine(),
                    processor: RuleBasedPostProcessor(),
                    inserter: inserter
                )
            }
        )

        _ = try runner.startRecording()
        let stopTask = Task { try await runner.stopDictation(selectedMode: .raw) }
        try await Task.sleep(for: .milliseconds(100))
        stopTask.cancel()

        await #expect(throws: CancellationError.self) {
            try await stopTask.value
        }
        #expect(inserter.insertedTexts.isEmpty, "A cancelled dictation must never insert text")
        #expect(historyWriter.appendedRecords.isEmpty, "A cancelled dictation must not linger in history")
        #expect(runner.state == .idle, "The runner must return to idle after a cancelled dictation")
    }
}

private final class FakeHistoryWriter: TranscriptHistoryWriting, @unchecked Sendable {
    private(set) var appendedRecords: [TranscriptRecord] = []

    func append(_ record: TranscriptRecord) throws {
        appendedRecords.append(record)
    }
}

private final class FakeSessionTextInserter: TextInserter, @unchecked Sendable {
    var insertedTexts: [String] = []

    func insert(_ text: String) throws {
        insertedTexts.append(text)
    }
}
