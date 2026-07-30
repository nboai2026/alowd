import Foundation

public final class RuleBasedPostProcessor: PostProcessor {
    public init() {}

    public func process(_ input: PostProcessingInput) async throws -> String {
        if input.mode == .raw {
            // Raw mode skips rewriting, but dictionary replacement rules are
            // user-requested spelling corrections and always apply.
            return applyDictionary(input.rawText, dictionary: input.dictionary)
        }

        var text = applyDictionary(input.rawText, dictionary: input.dictionary)
        text = SnippetExpander(snippets: input.snippets).expand(text)
        text = normalizePathSpeech(text)

        if input.mode != .prompt {
            text = removeFillers(text)
            text = collapseWhitespace(text)
        }

        if input.mode == .myVoicePro {
            text = sentenceCase(text)
        }

        return text
    }

    /// Applies misspelling→correction rules on word boundaries so "cat" never
    /// rewrites the middle of "catalog".
    private func applyDictionary(_ text: String, dictionary: [DictionaryTerm]) -> String {
        dictionary.reduce(text) { current, term in
            let phrase = term.phrase.trimmingCharacters(in: .whitespaces)
            guard !phrase.isEmpty else { return current }
            var pattern = NSRegularExpression.escapedPattern(for: phrase)
            // \b only works next to word characters; skip it for phrases that
            // start or end with symbols (paths, slash commands...).
            if phrase.first?.isLetter == true || phrase.first?.isNumber == true {
                pattern = "\\b" + pattern
            }
            if phrase.last?.isLetter == true || phrase.last?.isNumber == true {
                pattern += "\\b"
            }
            return current.replacingOccurrences(
                of: pattern,
                with: NSRegularExpression.escapedTemplate(for: term.replacement),
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }

    private func removeFillers(_ text: String) -> String {
        let fillers = ["um", "uh", "you know", "like"]
        return fillers.reduce(text) { current, filler in
            current.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: filler))\\b",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }

    private func normalizePathSpeech(_ text: String) -> String {
        text
            .replacingOccurrences(of: " slash ", with: "/")
            .replacingOccurrences(of: " dash ", with: "-")
            .replacingOccurrences(of: " underscore ", with: "_")
            .replacingOccurrences(of: " quote ", with: "\"")
    }

    private func collapseWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
