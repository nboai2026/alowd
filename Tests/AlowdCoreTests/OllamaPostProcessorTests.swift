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

    /// Regression: the casual instruction used to be a terse one-liner, which
    /// the model read as licence to compress — 65% of the dictation kept, and
    /// text-speak the speaker never used. The prompt must keep telling it not
    /// to summarise.
    @Test func casualModeForbidsSummarisingAndSlang() async throws {
        let client = FakeOllamaHTTPClient(responseText: "ok", shouldFail: false)
        let processor = OllamaPostProcessor(config: .default, client: client, fallback: RuleBasedPostProcessor())
        _ = try await processor.process(PostProcessingInput(
            rawText: "So basically, um, we should ship it today.",
            mode: .myVoiceCasual,
            dictionary: [],
            snippets: []
        ))
        let prompt = try #require(client.prompts.first)
        #expect(prompt.contains("Do not summarise"), "Casual mode must forbid summarising")
        #expect(prompt.contains("do not drop content"), "Casual mode must forbid dropping what was said")
        #expect(prompt.contains("more slangy"), "Casual mode must forbid inventing slang the speaker did not use")
        #expect(prompt.contains("their own order"), "Casual mode must preserve the speaker's ordering")
    }

    @Test func languageNamesAreHumanReadable() {
        #expect(OllamaPostProcessor.languageName(for: "fr") == "French")
        #expect(OllamaPostProcessor.languageName(for: "pt") == "Portuguese")
        #expect(OllamaPostProcessor.languageName(for: "zz") == "zz", "Unknown codes fall back to the code itself")
    }
}

/// Regression: a long dictation phrased as a request was read by the model as
/// an instruction addressed to it. Asked to "do a whole analysis based on all
/// that data", it wrote the analysis — inventing findings ("we succeeded in
/// reach and awareness... we failed on targeting") and pasting them in as the
/// user's own words. Seen in real history, and reproduced in four of six runs
/// on that transcript.
struct OllamaInstructionFollowingGuardTests {
    private func makeInput(_ raw: String) -> PostProcessingInput {
        PostProcessingInput(rawText: raw, mode: .myVoiceCasual, dictionary: [], snippets: [])
    }

    @Test func longTranscriptsNeverReachTheModel() async throws {
        let client = FakeOllamaHTTPClient(responseText: "a composed document", shouldFail: false)
        let processor = OllamaPostProcessor(config: .default, client: client, fallback: RuleBasedPostProcessor())
        let long = String(repeating: "word ", count: OllamaPostProcessor.maximumRewriteLength)
        #expect(long.count > OllamaPostProcessor.maximumRewriteLength)

        _ = try await processor.process(makeInput(long))
        #expect(client.prompts.isEmpty, "Past the length limit the rewrite must be skipped entirely")
    }

    @Test func transcriptsAtTheLimitStillGetRewritten() async throws {
        let client = FakeOllamaHTTPClient(responseText: "tidied up", shouldFail: false)
        let processor = OllamaPostProcessor(config: .default, client: client, fallback: RuleBasedPostProcessor())
        let atLimit = String(repeating: "a", count: OllamaPostProcessor.maximumRewriteLength)

        let output = try await processor.process(makeInput(atLimit))
        #expect(client.prompts.count == 1, "The limit is inclusive; ordinary dictation must still be rewritten")
        #expect(output == "tidied up")
    }

    @Test func aRewriteThatComposedADocumentIsRejected() async throws {
        // Dictation has no Markdown, so structure in the answer means the model
        // wrote a report instead of rewriting what was said.
        for composed in [
            "Here's the post-mortem:\n\n**Goal vs Result**\nWe went viral.",
            "Summary\n\n## Findings\nWe missed the target persona.",
            "Analysis:\n- reach was good\n- targeting failed",
            "Issues with the content:\n1. JC posts lack creative\n2. IG is the same"
        ] {
            let client = FakeOllamaHTTPClient(responseText: composed, shouldFail: false)
            let processor = OllamaPostProcessor(config: .default, client: client, fallback: RuleBasedPostProcessor())
            let output = try await processor.process(makeInput("I want you to do a whole analysis of that data."))
            #expect(output != composed, "A composed document must be rejected, not pasted into the user's field")
        }
    }

    @Test func anOrdinaryRewritePassesThrough() async throws {
        let client = FakeOllamaHTTPClient(responseText: "Check my emails and calendar for this week.", shouldFail: false)
        let processor = OllamaPostProcessor(config: .default, client: client, fallback: RuleBasedPostProcessor())
        let output = try await processor.process(makeInput("So I need you to check my emails and, um, the calendar for this week."))
        #expect(output == "Check my emails and calendar for this week.", "Prose rewrites must not be caught by the structure guard")
    }

    @Test func structureIsOnlySuspiciousWhenTheTranscriptLackedIt() {
        let structured = "- one\n- two"
        #expect(OllamaPostProcessor.composedADocument(from: "plain speech", into: structured))
        #expect(
            !OllamaPostProcessor.composedADocument(from: structured, into: structured),
            "Structure already present in the source is not evidence the model composed anything"
        )
    }

    @Test func markdownDetectionIgnoresOrdinarySpeech() {
        for markdown in ["**bold**", "# Heading", "### Deep", "- bullet", "* bullet", "• bullet", "1. first", "2) second"] {
            #expect(OllamaPostProcessor.containsMarkdownStructure(markdown), "\(markdown) is Markdown structure")
        }
        // Things dictation genuinely produces, which must not trip the guard.
        for prose in [
            "Ship it #1 priority",
            "Post it with #growth and #saas",
            "It cost 3.5 million in 2024",
            "The margin was 12.5 percent",
            "Well-known and self-serve are hyphenated",
            "I said no—then changed my mind",
            "Use 5 * 3 for the maths"
        ] {
            #expect(!OllamaPostProcessor.containsMarkdownStructure(prose), "\(prose) is ordinary speech")
        }
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
