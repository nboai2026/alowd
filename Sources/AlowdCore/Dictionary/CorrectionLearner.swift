import Foundation

/// Replicates Wispr Flow's auto-learning mechanism locally: diff the text
/// Alowd inserted against what the target field contains a little later,
/// and turn the user's manual edits into dictionary suggestions.
///
/// Only distinctive tokens are learned: at least 3 characters, not pure
/// numbers, absent from the embedded English+French frequency list, and not
/// already in the dictionary.
public final class CorrectionLearner: Sendable {
    /// Bail out on pathological inputs instead of running an O(n²) diff.
    private static let maxTokens = 500

    private let existingReplacements: Set<String>

    public init(existingTerms: [DictionaryTerm]) {
        self.existingReplacements = Set(existingTerms.map { $0.replacement.lowercased() })
    }

    /// Word-level diff of `insertedText` (what Alowd pasted) against
    /// `currentFieldText` (what the field holds now). Substituted words become
    /// misspelling→correction suggestions; distinctive words the user added
    /// *between* dictated words become plain word suggestions.
    ///
    /// Text before the first dictated word or after the last one is never
    /// learned: the field legitimately contains content the user typed around
    /// the insertion (including, worst case, a password or token typed right
    /// after dictating), and none of it is a correction of dictated speech.
    public func learn(insertedText: String, currentFieldText: String) -> [DictionarySuggestion] {
        let inserted = Self.tokenize(insertedText)
        let current = Self.tokenize(currentFieldText)
        guard !inserted.isEmpty, !current.isEmpty else { return [] }
        guard inserted.count <= Self.maxTokens, current.count <= Self.maxTokens else { return [] }
        guard inserted != current else { return [] }

        var suggestions: [DictionarySuggestion] = []
        var seen = Set<String>()

        for edit in Self.diff(from: inserted, to: current) {
            switch edit {
            case let .substitution(original, corrected):
                guard isLearnable(corrected), corrected != original else { continue }
                append(
                    DictionarySuggestion(
                        phrase: original.lowercased(),
                        replacement: corrected,
                        source: "auto_correction"
                    ),
                    to: &suggestions, seen: &seen
                )
            case let .addition(word):
                guard isLearnable(word) else { continue }
                append(
                    DictionarySuggestion(
                        phrase: word.lowercased(),
                        replacement: word,
                        source: "auto_correction"
                    ),
                    to: &suggestions, seen: &seen
                )
            }
        }
        return suggestions
    }

    // MARK: - Filtering

    private func isLearnable(_ token: String) -> Bool {
        guard token.count >= 3 else { return false }
        guard !isPureNumber(token) else { return false }
        guard !CommonWords.contains(token) else { return false }
        guard !existingReplacements.contains(token.lowercased()) else { return false }
        return true
    }

    private func isPureNumber(_ token: String) -> Bool {
        let stripped = token.filter { !",.:%€$-".contains($0) }
        return !stripped.isEmpty && stripped.allSatisfy(\.isNumber)
    }

    private func append(
        _ suggestion: DictionarySuggestion,
        to suggestions: inout [DictionarySuggestion],
        seen: inout Set<String>
    ) {
        let key = suggestion.replacement.lowercased()
        guard !seen.contains(key) else { return }
        seen.insert(key)
        suggestions.append(suggestion)
    }

    // MARK: - Word-level diff

    enum Edit: Equatable {
        case substitution(original: String, corrected: String)
        case addition(String)
    }

    /// Splits on whitespace and strips surrounding punctuation, keeping
    /// intra-word characters (hyphens, apostrophes, slashes) intact.
    static func tokenize(_ text: String) -> [String] {
        let trimSet = CharacterSet.punctuationCharacters
            .union(.symbols)
            .subtracting(CharacterSet(charactersIn: "/\\@#"))
        return text
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: trimSet) }
            .filter { !$0.isEmpty }
    }

    /// LCS-anchored diff. Between anchors, when the same number of tokens was
    /// removed and added they are paired positionally as substitutions —
    /// but only when the pair looks like a respelling of the same word
    /// (diacritic/case-folded equality or a small edit distance), so a fully
    /// rewritten sentence does not produce bogus replacement rules. All other
    /// added tokens surface as plain additions.
    static func diff(from old: [String], to new: [String]) -> [Edit] {
        // LCS table over exact tokens so case-only respellings show up as edits.
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                lcs[i][j] = old[i] == new[j]
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var edits: [Edit] = []
        var i = 0
        var j = 0
        var anchorSeen = false
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, old[i] == new[j] {
                anchorSeen = true
                i += 1
                j += 1
                continue
            }
            // Collect the whole mismatched run up to the next anchor.
            var removed: [String] = []
            var added: [String] = []
            while i < old.count || j < new.count {
                if i < old.count, j < new.count, old[i] == new[j] { break }
                if j == new.count || (i < old.count && lcs[i + 1][j] >= lcs[i][j + 1]) {
                    removed.append(old[i])
                    i += 1
                } else {
                    added.append(new[j])
                    j += 1
                }
            }
            // A run is interior only when dictated words anchor it on both
            // sides. Leading/trailing runs are surrounding field content, not
            // corrections — learning from them would capture whatever the user
            // typed around the insertion (secrets included).
            let interior = anchorSeen && i < old.count && j < new.count
            edits.append(contentsOf: pair(removed: removed, added: added, interior: interior))
        }
        return edits
    }

    private static func pair(removed: [String], added: [String], interior: Bool) -> [Edit] {
        if removed.count == added.count {
            return zip(removed, added).compactMap { original, corrected in
                if looksLikeRespelling(original, corrected) {
                    return .substitution(original: original, corrected: corrected)
                }
                return interior ? .addition(corrected) : nil
            }
        }
        return interior ? added.map(Edit.addition) : []
    }

    static func looksLikeRespelling(_ original: String, _ corrected: String) -> Bool {
        let a = CommonWords.normalize(original)
        let b = CommonWords.normalize(corrected)
        if a == b { return true }
        let tolerance = max(2, min(a.count, b.count) / 3)
        guard abs(a.count - b.count) <= tolerance else { return false }
        return editDistance(a, b) <= tolerance
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [Int](repeating: 0, count: b.count + 1)
            current[0] = i
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : min(previous[j - 1], previous[j], current[j - 1]) + 1
            }
            previous = current
        }
        return previous[b.count]
    }
}
