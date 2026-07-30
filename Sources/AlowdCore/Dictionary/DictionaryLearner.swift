import Foundation

public struct DictionarySuggestion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var phrase: String
    public var replacement: String
    public var source: String

    public init(id: UUID = UUID(), phrase: String, replacement: String, source: String) {
        self.id = id
        self.phrase = phrase
        self.replacement = replacement
        self.source = source
    }
}

public final class DictionaryLearner: Sendable {
    private let existingReplacements: Set<String>

    public init(existingTerms: [DictionaryTerm]) {
        self.existingReplacements = Set(existingTerms.map { $0.replacement.lowercased() })
    }

    public func suggestFromCorrection(before: String, after: String) -> [DictionarySuggestion] {
        let beforeTokens = Set(tokenize(before))
        let candidates = tokenize(after).filter { token in
            !beforeTokens.contains(token) && isLikelyPersonalTerm(token)
        }
        return uniqueSuggestions(candidates, source: "correction")
    }

    public func suggestFromSelectedText(_ text: String) -> [DictionarySuggestion] {
        uniqueSuggestions(tokenize(text).filter(isLikelyPersonalTerm), source: "selected_text")
    }

    private func tokenize(_ text: String) -> [String] {
        text.split { character in
            character.isWhitespace || [",", ".", ":", ";", "(", ")", "[", "]"].contains(character)
        }.map(String.init)
    }

    private func isLikelyPersonalTerm(_ token: String) -> Bool {
        if token.hasPrefix("/") { return true }
        if token.contains("-") && token.rangeOfCharacter(from: .uppercaseLetters) != nil { return true }
        if token.rangeOfCharacter(from: .uppercaseLetters) != nil && token.count >= 3 { return true }
        return false
    }

    private func uniqueSuggestions(_ tokens: [String], source: String) -> [DictionarySuggestion] {
        var seen = Set<String>()
        return tokens.compactMap { token in
            let key = token.lowercased()
            guard !existingReplacements.contains(key), !seen.contains(key) else { return nil }
            seen.insert(key)
            return DictionarySuggestion(phrase: token.lowercased(), replacement: token, source: source)
        }
    }
}
