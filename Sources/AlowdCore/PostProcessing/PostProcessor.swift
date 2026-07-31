import Foundation

public struct PostProcessingInput: Sendable {
    public var rawText: String
    public var mode: WritingMode
    public var dictionary: [DictionaryTerm]
    public var snippets: [Snippet]
    /// Language the transcript is in, when the engine reported one. An LLM
    /// given English instructions answers in English unless told otherwise —
    /// "Merci." comes back as "Thanks." — so the rewrite needs to know.
    public var language: String?

    public init(
        rawText: String,
        mode: WritingMode,
        dictionary: [DictionaryTerm],
        snippets: [Snippet],
        language: String? = nil
    ) {
        self.rawText = rawText
        self.mode = mode
        self.dictionary = dictionary
        self.snippets = snippets
        self.language = language
    }
}

public protocol PostProcessor: Sendable {
    func process(_ input: PostProcessingInput) async throws -> String
}
