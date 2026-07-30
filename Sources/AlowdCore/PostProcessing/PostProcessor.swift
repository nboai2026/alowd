import Foundation

public struct PostProcessingInput: Sendable {
    public var rawText: String
    public var mode: WritingMode
    public var dictionary: [DictionaryTerm]
    public var snippets: [Snippet]

    public init(rawText: String, mode: WritingMode, dictionary: [DictionaryTerm], snippets: [Snippet]) {
        self.rawText = rawText
        self.mode = mode
        self.dictionary = dictionary
        self.snippets = snippets
    }
}

public protocol PostProcessor: Sendable {
    func process(_ input: PostProcessingInput) async throws -> String
}
