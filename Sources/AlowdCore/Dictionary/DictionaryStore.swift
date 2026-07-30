import Foundation

/// CRUD store for dictionary terms (`data/dictionary.json`, same array format
/// `ProfileStore` reads) and pending auto-learn suggestions
/// (`data/dictionary-suggestions.json`), plus CSV import/export.
public final class DictionaryStore: @unchecked Sendable {
    private let termsURL: URL
    private let suggestionsURL: URL
    private let encoder = AlowdJSONCoding.makeEncoder()
    private let decoder = AlowdJSONCoding.makeDecoder()

    public init(root: URL) {
        let data = root.appendingPathComponent("data", isDirectory: true)
        self.termsURL = data.appendingPathComponent("dictionary.json")
        self.suggestionsURL = data.appendingPathComponent("dictionary-suggestions.json")
    }

    // MARK: - Terms

    public func loadTerms() throws -> [DictionaryTerm] {
        try load([DictionaryTerm].self, from: termsURL)
    }

    public func saveTerms(_ terms: [DictionaryTerm]) throws {
        try save(terms, to: termsURL)
    }

    public func addTerm(_ term: DictionaryTerm) throws {
        var terms = try loadTerms()
        terms.append(term)
        try saveTerms(terms)
    }

    /// Replaces the stored term with the same id; unknown ids are a no-op.
    public func updateTerm(_ term: DictionaryTerm) throws {
        var terms = try loadTerms()
        guard let index = terms.firstIndex(where: { $0.id == term.id }) else { return }
        terms[index] = term
        try saveTerms(terms)
    }

    public func deleteTerm(id: UUID) throws {
        var terms = try loadTerms()
        terms.removeAll { $0.id == id }
        try saveTerms(terms)
    }

    // MARK: - Pending suggestions

    public func loadSuggestions() throws -> [DictionarySuggestion] {
        try load([DictionarySuggestion].self, from: suggestionsURL)
    }

    /// Appends suggestions, skipping any whose replacement already exists as a
    /// term replacement or pending suggestion (case-insensitive). Returns the
    /// number actually added.
    @discardableResult
    public func appendSuggestions(_ suggestions: [DictionarySuggestion]) throws -> Int {
        var pending = try loadSuggestions()
        let terms = try loadTerms()
        var known = Set(terms.map { $0.replacement.lowercased() })
        known.formUnion(pending.map { $0.replacement.lowercased() })

        var added = 0
        for suggestion in suggestions {
            let key = suggestion.replacement.lowercased()
            guard !known.contains(key) else { continue }
            known.insert(key)
            pending.append(suggestion)
            added += 1
        }
        if added > 0 {
            try save(pending, to: suggestionsURL)
        }
        return added
    }

    /// Promotes a pending suggestion into a dictionary term and removes it
    /// from the queue.
    public func acceptSuggestion(id: UUID) throws {
        var pending = try loadSuggestions()
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let suggestion = pending.remove(at: index)
        try addTerm(DictionaryTerm(
            phrase: suggestion.phrase,
            replacement: suggestion.replacement,
            source: suggestion.source
        ))
        try save(pending, to: suggestionsURL)
    }

    public func rejectSuggestion(id: UUID) throws {
        var pending = try loadSuggestions()
        pending.removeAll { $0.id == id }
        try save(pending, to: suggestionsURL)
    }

    // MARK: - CSV import/export

    /// Exports terms as "word,misspelling" CSV. `word` is the corrected
    /// replacement; `misspelling` the phrase that triggers it (blank when the
    /// phrase is just the lowercased word).
    public static func exportCSV(_ terms: [DictionaryTerm]) -> String {
        var lines = ["word,misspelling"]
        for term in terms {
            let misspelling = term.phrase == term.replacement.lowercased() ? "" : term.phrase
            lines.append("\(escapeCSVField(term.replacement)),\(escapeCSVField(misspelling))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Tolerant "word,misspelling" CSV parsing: skips a header row, blank
    /// lines, and rows without a word; handles quoted fields, CRLF, and rows
    /// with only the word column. Rows never fail the whole import.
    public static func importCSV(_ text: String) -> [DictionaryTerm] {
        var terms: [DictionaryTerm] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let fields = parseCSVLine(line)
            guard let word = fields.first?.trimmingCharacters(in: .whitespaces), !word.isEmpty else { continue }
            if word.lowercased() == "word" { continue } // header row
            let misspelling = fields.count > 1
                ? fields[1].trimmingCharacters(in: .whitespaces)
                : ""
            terms.append(DictionaryTerm(
                phrase: misspelling.isEmpty ? word.lowercased() : misspelling,
                replacement: word,
                source: "csv_import"
            ))
        }
        return terms
    }

    /// Merges imported terms into the store, skipping any whose
    /// phrase→replacement pair already exists (case-insensitive). Returns the
    /// number actually added.
    @discardableResult
    public func mergeImportedTerms(_ imported: [DictionaryTerm]) throws -> Int {
        var terms = try loadTerms()
        var known = Set(terms.map { "\($0.phrase.lowercased())→\($0.replacement.lowercased())" })
        var added = 0
        for term in imported {
            let key = "\(term.phrase.lowercased())→\(term.replacement.lowercased())"
            guard !known.contains(key) else { continue }
            known.insert(key)
            terms.append(term)
            added += 1
        }
        if added > 0 {
            try saveTerms(terms)
        }
        return added
    }

    // MARK: - Helpers

    private func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T where T: RangeReplaceableCollection {
        guard FileManager.default.fileExists(atPath: url.path) else { return T() }
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(value).write(to: url, options: [.atomic])
    }

    private static func escapeCSVField(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        var pending: Character? = iterator.next()

        while let character = pending {
            pending = iterator.next()
            if inQuotes {
                if character == "\"" {
                    if pending == "\"" { // escaped quote
                        current.append("\"")
                        pending = iterator.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)
        return fields
    }
}
