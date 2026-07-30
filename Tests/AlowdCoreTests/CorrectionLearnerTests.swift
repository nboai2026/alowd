import Foundation
import Testing
@testable import AlowdCore

struct CorrectionLearnerTests {
    @Test func learnsRespelledWordAsReplacementRule() {
        let learner = CorrectionLearner(existingTerms: [])
        let suggestions = learner.learn(
            insertedText: "open the whisperkid model",
            currentFieldText: "open the WhisperKit model"
        )
        #expect(suggestions.count == 1, "A single respelling yields one suggestion")
        #expect(suggestions.first?.phrase == "whisperkid", "The misspelling becomes the phrase")
        #expect(suggestions.first?.replacement == "WhisperKit", "The corrected word becomes the replacement")
        #expect(suggestions.first?.source == "auto_correction", "Learned suggestions carry the auto_correction source")
    }

    @Test func learnsCaseOnlyCorrection() {
        let learner = CorrectionLearner(existingTerms: [])
        let suggestions = learner.learn(
            insertedText: "ask nbo about it",
            currentFieldText: "ask NBO about it"
        )
        #expect(suggestions.map(\.replacement) == ["NBO"], "Case-only respellings must be learned")
        #expect(suggestions.first?.phrase == "nbo", "Phrase is the lowercased original")
    }

    @Test func identicalTextsLearnNothing() {
        let learner = CorrectionLearner(existingTerms: [])
        #expect(learner.learn(insertedText: "hello world", currentFieldText: "hello world").isEmpty, "No edit means no suggestion")
    }

    @Test func emptyFieldLearnsNothing() {
        let learner = CorrectionLearner(existingTerms: [])
        #expect(learner.learn(insertedText: "hello world", currentFieldText: "").isEmpty, "An empty field read must be ignored")
        #expect(learner.learn(insertedText: "", currentFieldText: "hello").isEmpty, "Nothing inserted means nothing to diff")
    }

    @Test func filtersCommonEnglishAndFrenchWords() {
        let learner = CorrectionLearner(existingTerms: [])
        let suggestions = learner.learn(
            insertedText: "the maison is big",
            currentFieldText: "the Kubernetes house is big"
        )
        #expect(!suggestions.contains { $0.replacement.lowercased() == "house" }, "Common English words must not be learned")
        #expect(suggestions.map(\.replacement) == ["Kubernetes"], "Distinctive terms must still be learned")
    }

    @Test func textTypedAfterTheInsertionIsNeverLearned() {
        let learner = CorrectionLearner(existingTerms: [])
        // The field holds the dictation plus something typed afterwards — for
        // example a token or password. Nothing past the last dictated word may
        // ever become a suggestion.
        let suggestions = learner.learn(
            insertedText: "send the deploy summary",
            currentFieldText: "send the deploy summary sk-live-verysecret123"
        )
        #expect(suggestions.isEmpty, "Trailing text typed after the insertion must never be learned")
    }

    @Test func textTypedBeforeTheInsertionIsNeverLearned() {
        let learner = CorrectionLearner(existingTerms: [])
        let suggestions = learner.learn(
            insertedText: "send the deploy summary",
            currentFieldText: "Xylophone7 send the deploy summary"
        )
        #expect(suggestions.isEmpty, "Leading text the user typed before the insertion must never be learned")
    }

    @Test func filtersAccentedFrenchCommonWords() {
        let learner = CorrectionLearner(existingTerms: [])
        let suggestions = learner.learn(
            insertedText: "cet ete on part",
            currentFieldText: "cet été on part"
        )
        #expect(suggestions.isEmpty, "Accented forms of common French words must be filtered")
    }

    @Test func filtersShortTokensAndNumbers() {
        let learner = CorrectionLearner(existingTerms: [])
        let suggestions = learner.learn(
            insertedText: "pay 1000 to xy now zzkj",
            currentFieldText: "pay 2,500 to ab now Zzkj"
        )
        #expect(!suggestions.contains { $0.replacement == "2,500" }, "Pure numbers must not be learned")
        #expect(!suggestions.contains { $0.replacement == "ab" }, "Tokens under 3 characters must not be learned")
        #expect(suggestions.map(\.replacement) == ["Zzkj"], "Distinctive respellings still pass")
    }

    @Test func doesNotDuplicateExistingTerms() {
        let learner = CorrectionLearner(existingTerms: [
            DictionaryTerm(phrase: "whisperkid", replacement: "WhisperKit", source: "manual")
        ])
        let suggestions = learner.learn(
            insertedText: "use whisperkid here",
            currentFieldText: "use WhisperKit here"
        )
        #expect(suggestions.isEmpty, "Words already in the dictionary must not be re-learned")
    }

    @Test func learnsAddedDistinctiveWordWithoutRule() {
        let learner = CorrectionLearner(existingTerms: [])
        let suggestions = learner.learn(
            insertedText: "deploy the service",
            currentFieldText: "deploy the Traefik service"
        )
        #expect(suggestions.count == 1, "A single added word yields one suggestion")
        #expect(suggestions.first?.phrase == "traefik", "Added words use their lowercased form as phrase")
        #expect(suggestions.first?.replacement == "Traefik", "Added words are learned as-is")
    }

    @Test func fullRewriteDoesNotCreateBogusRules() {
        let learner = CorrectionLearner(existingTerms: [])
        let suggestions = learner.learn(
            insertedText: "send the report tomorrow",
            currentFieldText: "Grafana dashboards look great"
        )
        // A full rewrite shares no anchors with the insertion, so nothing may
        // be learned at all — neither bogus rules nor plain additions.
        #expect(suggestions.isEmpty, "A fully rewritten field must not produce any suggestions")
    }

    @Test func surroundingFieldTextDoesNotBreakSubstitutionDetection() {
        let learner = CorrectionLearner(existingTerms: [])
        let suggestions = learner.learn(
            insertedText: "check the postgress logs",
            currentFieldText: "Hi team, check the Postgres logs please"
        )
        #expect(suggestions.contains { $0.phrase == "postgress" && $0.replacement == "Postgres" }, "Substitutions must survive extra field content")
    }

    @Test func tokenizerStripsPunctuationButKeepsPathsAndHyphens() {
        let tokens = CorrectionLearner.tokenize("Hello, world! Use /usr/bin and re-try (now).")
        #expect(tokens == ["Hello", "world", "Use", "/usr/bin", "and", "re-try", "now"], "Tokenizer must strip surrounding punctuation and keep paths/hyphens")
    }

    @Test func deduplicatesRepeatedCorrections() {
        let learner = CorrectionLearner(existingTerms: [])
        let suggestions = learner.learn(
            insertedText: "whisperkid then whisperkid again",
            currentFieldText: "WhisperKit then WhisperKit again"
        )
        #expect(suggestions.count == 1, "The same correction must be suggested once")
    }
}

struct CommonWordsTests {
    @Test func containsCoreEnglishAndFrench() {
        #expect(CommonWords.contains("the"), "English frequency words must match")
        #expect(CommonWords.contains("Maison"), "Lookup must be case-insensitive")
        #expect(CommonWords.contains("être"), "Accented French forms must match the folded list")
        #expect(CommonWords.contains("don't"), "Apostrophes must be ignored")
    }

    @Test func doesNotContainDistinctiveTerms() {
        #expect(!CommonWords.contains("WhisperKit"), "Technical terms must not be in the list")
        #expect(!CommonWords.contains("Grafana"), "Product names must not be in the list")
    }

    @Test func listIsRoughlyTwoThousandWords() {
        #expect(CommonWords.words.count > 1500, "Frequency list must stay substantial (has \(CommonWords.words.count))")
    }
}
