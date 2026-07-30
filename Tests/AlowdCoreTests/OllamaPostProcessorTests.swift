import Foundation
import Testing
@testable import AlowdCore

struct OllamaPostProcessorTests {
    @Test func rawModeBypassesOllama() async throws {
        let client = FakeOllamaHTTPClient(responseText: "rewritten", shouldFail: false)
        let processor = OllamaPostProcessor(config: .default, client: client, fallback: RuleBasedPostProcessor())
        let input = PostProcessingInput(rawText: "keep exactly", mode: .raw, dictionary: [], snippets: [])
        let output = try await processor.process(input)
        #expect(output == "keep exactly", "Raw mode must bypass Ollama")
        #expect(client.prompts.isEmpty, "Raw mode must not send prompts to Ollama")
    }

    @Test func promptModeCallsLocalOllama() async throws {
        let client = FakeOllamaHTTPClient(responseText: "Use /Users/example/project and run rg", shouldFail: false)
        let processor = OllamaPostProcessor(config: .default, client: client, fallback: RuleBasedPostProcessor())
        let input = PostProcessingInput(rawText: "use slash Users slash example slash project and run rg", mode: .prompt, dictionary: [], snippets: [])
        let output = try await processor.process(input)
        #expect(output == "Use /Users/example/project and run rg", "Prompt mode must return local Ollama response")
        #expect(client.prompts.count == 1, "Prompt mode must call Ollama once")
    }

    @Test func ollamaFailureFallsBackToRules() async throws {
        let client = FakeOllamaHTTPClient(responseText: "", shouldFail: true)
        let processor = OllamaPostProcessor(config: .default, client: client, fallback: RuleBasedPostProcessor())
        let input = PostProcessingInput(rawText: "um hello", mode: .myVoiceCasual, dictionary: [], snippets: [])
        let output = try await processor.process(input)
        #expect(output == "hello", "Ollama failure must fall back to rules")
    }
}

private final class FakeOllamaHTTPClient: OllamaHTTPClient, @unchecked Sendable {
    var prompts: [String] = []
    let responseText: String
    let shouldFail: Bool

    init(responseText: String, shouldFail: Bool) {
        self.responseText = responseText
        self.shouldFail = shouldFail
    }

    func generate(prompt: String, config: OllamaConfig) async throws -> String {
        prompts.append(prompt)
        if shouldFail { throw URLError(.cannotConnectToHost) }
        return responseText
    }
}

struct OllamaReasoningStripperTests {
    @Test func answerAfterThinkMarkerIsUsed() throws {
        let raw = "Okay, the user wants a rewrite. I should be concise.</think>\n\nThe dashboard was slow yesterday."
        #expect(try OllamaReasoningStripper.answer(from: raw, truncated: false) == "The dashboard was slow yesterday.")
    }

    @Test func plainAnswerWithoutMarkerPassesThrough() throws {
        #expect(try OllamaReasoningStripper.answer(from: "  Clean text.  ", truncated: false) == "Clean text.")
    }

    @Test func reasoningWithNoAnswerIsRejected() {
        let raw = "Okay, the user wants me to rewrite this. Let me think.</think>   "
        #expect(throws: OllamaResponseError.noAnswerAfterReasoning) {
            try OllamaReasoningStripper.answer(from: raw, truncated: false)
        }
    }

    @Test func truncatedReasoningWithoutMarkerIsRejected() {
        // The exact shape that would otherwise paste "Okay, the user wants..."
        // into the user's document.
        let raw = "Okay, the user wants me to rewrite a sentence professionally and the original"
        #expect(throws: OllamaResponseError.noAnswerAfterReasoning) {
            try OllamaReasoningStripper.answer(from: raw, truncated: true)
        }
    }
}
