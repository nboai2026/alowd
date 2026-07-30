import Foundation
import Testing
@testable import AlowdCore

struct DictionaryLearnerTests {
    @Test func suggestsCorrectionForCapitalizationAndSpelling() {
        let learner = DictionaryLearner(existingTerms: [])
        let suggestions = learner.suggestFromCorrection(before: "open nbo memory", after: "open NBO memory")
        #expect(suggestions.map(\.replacement) == ["NBO"], "Correction must suggest changed technical term")
        #expect(suggestions.first?.source == "correction", "Correction suggestions must carry source")
    }

    @Test func suggestsLikelyTechnicalTermsFromSelectedText() {
        let learner = DictionaryLearner(existingTerms: [])
        let suggestions = learner.suggestFromSelectedText("Use WhisperKit with /Users/example/project and PROJECT-ALPHA.")
        #expect(suggestions.contains { $0.replacement == "WhisperKit" }, "Selected text must suggest camel-case terms")
        #expect(suggestions.contains { $0.replacement == "/Users/example/project" }, "Selected text must suggest paths")
        #expect(suggestions.contains { $0.replacement == "PROJECT-ALPHA" }, "Selected text must suggest uppercase hyphenated terms")
    }

    @Test func doesNotDuplicateExistingTerms() {
        let learner = DictionaryLearner(existingTerms: [DictionaryTerm(phrase: "nbo", replacement: "NBO", source: "manual")])
        let suggestions = learner.suggestFromCorrection(before: "nbo", after: "NBO")
        #expect(suggestions.isEmpty, "Existing terms must not be duplicated")
    }
}
