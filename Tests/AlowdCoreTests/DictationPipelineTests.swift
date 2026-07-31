import Foundation
import Testing
@testable import AlowdCore

struct DictationPipelineTests {
    @Test func pipelineTranscribesProcessesAndInserts() async throws {
        let inserter = FakeTextInserter()
        let pipeline = DictationPipeline(
            engine: StubTranscriptionEngine(text: "um hello nbo"),
            processor: RuleBasedPostProcessor(),
            inserter: inserter
        )

        let inserted = try await pipeline.finishDictation(
            audioFile: URL(fileURLWithPath: "/tmp/fake.wav"),
            mode: .myVoiceCasual,
            dictionary: [DictionaryTerm(phrase: "nbo", replacement: "NBO", source: "test")],
            snippets: []
        )

        #expect(inserted == "hello NBO", "Pipeline must return final processed text")
        #expect(inserter.insertedTexts == ["hello NBO"], "Pipeline must insert final text")
    }
}

private final class FakeTextInserter: TextInserter, @unchecked Sendable {
    var insertedTexts: [String] = []

    func insert(_ text: String) throws {
        insertedTexts.append(text)
    }
}

struct DetectedLanguageReportingTests {
    private struct LanguageReportingEngine: TranscriptionEngine {
        let language: String?
        func transcribe(audioFile: URL) async throws -> TranscriptResult {
            TranscriptResult(text: "bonjour le monde", confidence: 1, language: language)
        }
    }

    @Test func pipelineReportsTheDecodedLanguage() async throws {
        let pipeline = DictationPipeline(
            engine: LanguageReportingEngine(language: "fr"),
            processor: RuleBasedPostProcessor(),
            inserter: RecordingInserter()
        )
        let result = try await pipeline.produceTextTimed(
            audioFile: URL(fileURLWithPath: "/tmp/none.wav"),
            mode: .raw,
            dictionary: [],
            snippets: []
        )
        #expect(result.language == "fr", "The decoded language must reach the caller so the UI can show it")
    }

    @Test func missingLanguageIsReportedAsNil() async throws {
        let pipeline = DictationPipeline(
            engine: LanguageReportingEngine(language: nil),
            processor: RuleBasedPostProcessor(),
            inserter: RecordingInserter()
        )
        let result = try await pipeline.produceTextTimed(
            audioFile: URL(fileURLWithPath: "/tmp/none.wav"),
            mode: .raw,
            dictionary: [],
            snippets: []
        )
        #expect(result.language == nil, "An engine that reports no language must not invent one")
    }
}

private final class RecordingInserter: TextInserter, @unchecked Sendable {
    func insert(_ text: String) throws {}
}
