import Foundation

public final class SnippetExpander: Sendable {
    private let snippets: [Snippet]

    public init(snippets: [Snippet]) {
        self.snippets = snippets
    }

    public func expand(_ text: String) -> String {
        snippets.reduce(text) { current, snippet in
            current.replacingOccurrences(
                of: snippet.trigger,
                with: snippet.expansion,
                options: [.caseInsensitive]
            )
        }
    }
}
