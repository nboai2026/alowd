import Foundation
import Testing
@testable import AlowdCore

struct PostProcessorTests {
    @Test func rawModeDoesNotRewrite() async throws {
        let processor = RuleBasedPostProcessor()
        let input = PostProcessingInput(rawText: "um open slash Users slash example", mode: .raw, dictionary: [], snippets: [])
        let output = try await processor.process(input)
        #expect(output == "um open slash Users slash example", "Raw mode must not rewrite text")
    }

    @Test func casualModeRemovesFillers() async throws {
        let processor = RuleBasedPostProcessor()
        let input = PostProcessingInput(rawText: "um hey can you uh send this", mode: .myVoiceCasual, dictionary: [], snippets: [])
        let output = try await processor.process(input)
        #expect(output == "hey can you send this", "Casual mode must remove fillers")
    }

    @Test func promptModePreservesCodeTokens() async throws {
        let processor = RuleBasedPostProcessor()
        let input = PostProcessingInput(
            rawText: "run rg dash n quote needle quote slash Users slash example slash project",
            mode: .prompt,
            dictionary: [],
            snippets: []
        )
        let output = try await processor.process(input)
        #expect(output.contains("rg"), "Prompt mode must preserve command tokens")
        #expect(output.contains("needle"), "Prompt mode must preserve quoted text")
        #expect(output.contains("/Users/example/project"), "Prompt mode must preserve exact paths")
    }

    @Test func rawModeStillAppliesDictionaryRules() async throws {
        let processor = RuleBasedPostProcessor()
        let input = PostProcessingInput(
            rawText: "um ask whisperkid about it",
            mode: .raw,
            dictionary: [DictionaryTerm(phrase: "whisperkid", replacement: "WhisperKit", source: "manual")],
            snippets: []
        )
        let output = try await processor.process(input)
        #expect(output == "um ask WhisperKit about it", "Raw mode must apply spelling corrections but nothing else")
    }

    @Test func dictionaryReplacementRespectsWordBoundaries() async throws {
        let processor = RuleBasedPostProcessor()
        let input = PostProcessingInput(
            rawText: "the cat browsed the catalog",
            mode: .myVoiceCasual,
            dictionary: [DictionaryTerm(phrase: "cat", replacement: "Kat", source: "manual")],
            snippets: []
        )
        let output = try await processor.process(input)
        #expect(output == "the Kat browsed the catalog", "Rules must not rewrite inside longer words")
    }

    @Test func dictionaryReplacementIsCaseInsensitiveAndHandlesPhrases() async throws {
        let processor = RuleBasedPostProcessor()
        let input = PostProcessingInput(
            rawText: "Whisper Kid is loaded",
            mode: .myVoiceCasual,
            dictionary: [DictionaryTerm(phrase: "whisper kid", replacement: "WhisperKit", source: "manual")],
            snippets: []
        )
        let output = try await processor.process(input)
        #expect(output == "WhisperKit is loaded", "Multi-word phrases must replace case-insensitively")
    }

    @Test func snippetExpansion() {
        let expander = SnippetExpander(snippets: [Snippet(trigger: "calendar link", expansion: "https://example.com/calendar")])
        #expect(expander.expand("send calendar link") == "send https://example.com/calendar", "Snippet trigger must expand")
    }
}
