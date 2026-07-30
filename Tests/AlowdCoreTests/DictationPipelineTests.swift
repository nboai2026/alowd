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
