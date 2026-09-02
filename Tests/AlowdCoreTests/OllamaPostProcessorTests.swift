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

    /// Regression: an empty decode reached the model, which answered
    /// conversationally ("Sure! Please provide the transcript you'd like me to
    /// rewrite in your casual voice.") and that reply was pasted into the
    /// user's document. Seen in real history.
    @Test func emptyTranscriptNeverReachesOllama() async throws {
        let client = FakeOllamaHTTPClient(responseText: "Sure! Please provide the transcript.", shouldFail: false)
        let processor = OllamaPostProcessor(config: .default, client: client, fallback: RuleBasedPostProcessor())
        for blank in ["", "   ", "\n\t "] {
            let output = try await processor.process(PostProcessingInput(
                rawText: blank,
                mode: .myVoiceCasual,
                dictionary: [],
                snippets: []
            ))
            #expect(output == blank, "A blank transcript must come back blank, not as chat filler")
        }
        #expect(client.prompts.isEmpty, "A blank transcript must not be sent to Ollama")
    }

    @Test func ollamaFailureFallsBackToRules() async throws {
        let client = FakeOllamaHTTPClient(responseText: "", shouldFail: true)
        let processor = OllamaPostProcessor(config: .default, client: client, fallback: RuleBasedPostProcessor())
        let input = PostProcessingInput(rawText: "um hello", mode: .myVoiceCasual, dictionary: [], snippets: [])
        let output = try await processor.process(input)
        #expect(output == "hello", "Ollama failure must fall back to rules")
    }
}


struct OllamaLanguagePreservationTests {
    /// Regression: the rewrite instructions are English, and without an
    /// explicit rule qwen turned "Merci." into "Thanks." — verified against a
    /// real local model before this rule was added.
    @Test func promptNamesTheDetectedLanguage() async throws {
        let client = FakeOllamaHTTPClient(responseText: "Merci.", shouldFail: false)
        let processor = OllamaPostProcessor(
            config: .default,
            client: client,
            fallback: RuleBasedPostProcessor()
        )
        _ = try await processor.process(PostProcessingInput(
            rawText: "Merci.",
            mode: .myVoiceCasual,
            dictionary: [],
            snippets: [],
            language: "fr"
        ))
        let prompt = try #require(client.prompts.first)
        #expect(prompt.contains("French"), "The prompt must name the detected language")
        #expect(prompt.contains("Never translate"), "The prompt must forbid translation")
    }

    @Test func promptStillForbidsTranslationWithoutADetectedLanguage() async throws {
        let client = FakeOllamaHTTPClient(responseText: "ok", shouldFail: false)
        let processor = OllamaPostProcessor(
            config: .default,
            client: client,
            fallback: RuleBasedPostProcessor()
        )
        _ = try await processor.process(PostProcessingInput(
            rawText: "Merci.",
            mode: .myVoiceCasual,
            dictionary: [],
            snippets: [],
            language: nil
        ))
        let prompt = try #require(client.prompts.first)
        #expect(prompt.contains("same language as the transcript"), "Without a detected language the prompt must still pin the language")
        #expect(prompt.contains("Never translate"), "The prompt must forbid translation")
    }

    @Test func languageNamesAreHumanReadable() {
        #expect(OllamaPostProcessor.languageName(for: "fr") == "French")
        #expect(OllamaPostProcessor.languageName(for: "pt") == "Portuguese")
        #expect(OllamaPostProcessor.languageName(for: "zz") == "zz", "Unknown codes fall back to the code itself")
    }
}

/// The rewrite answers in about a second against a model Ollama already holds
/// in memory and takes tens of seconds against a cold one — past the request
/// timeout, so the rewrite is dropped. Abandoning the request also aborts the
/// load, so without these two fields the model never becomes resident and the
/// rewrite silently never runs at all.
struct OllamaResidencyTests {
    private func encoded(_ value: some Encodable) throws -> [String: Any] {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func configKeepsTheModelResidentLongerThanOllamasOwnDefault() {
        // Ollama unloads after five minutes by default, which is shorter than
        // the gap between dictations, so every one of them paid a cold load.
        #expect(OllamaConfig.default.keepAlive == "30m")
    }

    @Test func generateRequestAsksOllamaToKeepTheModelResident() throws {
        let config = OllamaConfig(baseURL: URL(string: "http://127.0.0.1:11434")!, model: "m", keepAlive: "45m")
        let json = try encoded(OllamaGenerateRequest(
            model: config.model,
            prompt: "hello",
            stream: false,
            keep_alive: config.keepAlive
        ))
        #expect(json["keep_alive"] as? String == "45m", "Every rewrite must renew the model's residency")
        #expect(json["prompt"] as? String == "hello")
        #expect(json["stream"] as? Bool == false)
    }

    @Test func preloadRequestLoadsTheModelWithoutGenerating() throws {
        // Ollama treats an empty prompt as a warm-up: it loads the weights and
        // answers `done_reason: "load"` rather than generating tokens.
        let json = try encoded(OllamaPreloadRequest(model: "m", keep_alive: "30m"))
        #expect(json["prompt"] as? String == "", "An empty prompt is what makes this a load rather than a generation")
        #expect(json["keep_alive"] as? String == "30m")
        #expect(json["model"] as? String == "m")
    }

    @Test func preloadIsOptionalForClientsThatCannotWarm() async throws {
        // The default implementation exists so fakes and non-HTTP clients are
        // not forced to implement warming; it must be a silent no-op.
        let client = FakeOllamaHTTPClient(responseText: "ok", shouldFail: false)
        try await client.preload(config: .default)
        #expect(client.prompts.isEmpty, "Warming must not look like a rewrite")
    }

    @Test func warmingGetsALongerBudgetThanADictation() {
        #expect(
            URLSessionOllamaHTTPClient.preloadTimeout > OllamaConfig.default.timeout,
            "Loading weights off disk is slower than answering with them, and warming blocks no one"
        )
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
