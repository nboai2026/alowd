import Foundation
import Testing
@testable import AlowdCore

struct DictionaryStoreTests {
    private func makeStore() throws -> (store: DictionaryStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alowd-dictionary-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (DictionaryStore(root: root), root)
    }

    @Test func emptyStoreLoadsNoTermsOrSuggestions() throws {
        let (store, _) = try makeStore()
        #expect(try store.loadTerms().isEmpty, "Missing files must load as empty")
        #expect(try store.loadSuggestions().isEmpty, "Missing files must load as empty")
    }

    @Test func termCRUDRoundTrip() throws {
        let (store, _) = try makeStore()
        let term = DictionaryTerm(phrase: "whisper kit", replacement: "WhisperKit", source: "manual")
        try store.addTerm(term)
        #expect(try store.loadTerms() == [term], "Added term must persist")

        var updated = term
        updated.replacement = "WhisperKit2"
        try store.updateTerm(updated)
        #expect(try store.loadTerms().first?.replacement == "WhisperKit2", "Update must replace by id")

        try store.deleteTerm(id: term.id)
        #expect(try store.loadTerms().isEmpty, "Delete must remove the term")
    }

    @Test func updateUnknownTermIsNoOp() throws {
        let (store, _) = try makeStore()
        try store.addTerm(DictionaryTerm(phrase: "a", replacement: "A", source: "manual"))
        try store.updateTerm(DictionaryTerm(phrase: "b", replacement: "B", source: "manual"))
        #expect(try store.loadTerms().count == 1, "Unknown-id update must not add a term")
    }

    @Test func onDiskFormatMatchesProfileStore() throws {
        let (store, root) = try makeStore()
        let term = DictionaryTerm(phrase: "nbo", replacement: "NBO", source: "manual")
        try store.addTerm(term)
        // ProfileStore reads the same file: the format must stay compatible.
        #expect(try ProfileStore(root: root).loadDictionary() == [term], "DictionaryStore must keep dictionary.json compatible with ProfileStore")

        try ProfileStore(root: root).saveDictionary([term])
        #expect(try store.loadTerms() == [term], "DictionaryStore must read ProfileStore-written files")
    }

    @Test func suggestionsAppendDeduplicatesAgainstTermsAndPending() throws {
        let (store, _) = try makeStore()
        try store.addTerm(DictionaryTerm(phrase: "nbo", replacement: "NBO", source: "manual"))
        let fresh = DictionarySuggestion(phrase: "whisperkit", replacement: "WhisperKit", source: "auto_correction")
        let duplicateOfTerm = DictionarySuggestion(phrase: "nbo", replacement: "nbo", source: "auto_correction")

        let added = try store.appendSuggestions([fresh, duplicateOfTerm, fresh])
        #expect(added == 1, "Only genuinely new suggestions count")
        #expect(try store.loadSuggestions() == [fresh], "Duplicates of terms and pending entries must be skipped")
    }

    @Test func acceptSuggestionPromotesToTerm() throws {
        let (store, _) = try makeStore()
        let suggestion = DictionarySuggestion(phrase: "claude", replacement: "Claude", source: "auto_correction")
        try store.appendSuggestions([suggestion])
        try store.acceptSuggestion(id: suggestion.id)

        #expect(try store.loadSuggestions().isEmpty, "Accepted suggestion must leave the queue")
        let terms = try store.loadTerms()
        #expect(terms.count == 1, "Accepted suggestion must become a term")
        #expect(terms.first?.phrase == "claude", "Term must keep the suggestion phrase")
        #expect(terms.first?.replacement == "Claude", "Term must keep the suggestion replacement")
    }

    @Test func rejectSuggestionRemovesOnlyThatSuggestion() throws {
        let (store, _) = try makeStore()
        let keep = DictionarySuggestion(phrase: "keepme", replacement: "KeepMe", source: "auto_correction")
        let drop = DictionarySuggestion(phrase: "dropme", replacement: "DropMe", source: "auto_correction")
        try store.appendSuggestions([keep, drop])
        try store.rejectSuggestion(id: drop.id)

        #expect(try store.loadSuggestions() == [keep], "Reject must remove only the given suggestion")
        #expect(try store.loadTerms().isEmpty, "Reject must not create a term")
    }

    @Test func csvExportUsesWordMisspellingColumns() {
        let csv = DictionaryStore.exportCSV([
            DictionaryTerm(phrase: "whisper kit", replacement: "WhisperKit", source: "manual"),
            DictionaryTerm(phrase: "nbo", replacement: "NBO", source: "manual"),
            DictionaryTerm(phrase: "a, b", replacement: "A\"B", source: "manual")
        ])
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines[0] == "word,misspelling", "Header must be word,misspelling")
        #expect(lines[1] == "WhisperKit,whisper kit", "Word then misspelling")
        #expect(lines[2] == "NBO,", "Misspelling column is blank when the phrase is just the lowercased word")
        #expect(lines[3] == "\"A\"\"B\",\"a, b\"", "Commas and quotes must be escaped")
    }

    @Test func csvImportIsTolerant() {
        let csv = """
        word,misspelling

        WhisperKit,whisper kit
        NBO
        "A, B",\"a b\"
        ,orphan
        Claude ,  cloud
        """
        let terms = DictionaryStore.importCSV(csv)
        #expect(terms.count == 4, "Header, blank lines and word-less rows must be skipped")
        #expect(terms[0].phrase == "whisper kit" && terms[0].replacement == "WhisperKit", "Standard row must parse")
        #expect(terms[1].phrase == "nbo" && terms[1].replacement == "NBO", "Missing misspelling falls back to the lowercased word")
        #expect(terms[2].phrase == "a b" && terms[2].replacement == "A, B", "Quoted fields must parse")
        #expect(terms[3].phrase == "cloud" && terms[3].replacement == "Claude", "Fields must be trimmed")
        #expect(terms.allSatisfy { $0.source == "csv_import" }, "Imported terms carry the csv_import source")
    }

    @Test func csvImportHandlesCRLF() {
        let terms = DictionaryStore.importCSV("word,misspelling\r\nNBO,nbo\r\n")
        #expect(terms.count == 1, "CRLF line endings must parse")
        #expect(terms[0].replacement == "NBO", "CRLF row must keep its word")
    }

    @Test func csvRoundTrip() throws {
        let (store, _) = try makeStore()
        let original = [
            DictionaryTerm(phrase: "whisper kit", replacement: "WhisperKit", source: "manual"),
            DictionaryTerm(phrase: "nbo", replacement: "NBO", source: "manual")
        ]
        let imported = DictionaryStore.importCSV(DictionaryStore.exportCSV(original))
        #expect(imported.map(\.phrase) == original.map(\.phrase), "Round trip must keep phrases")
        #expect(imported.map(\.replacement) == original.map(\.replacement), "Round trip must keep replacements")

        try store.saveTerms(original)
        let added = try store.mergeImportedTerms(imported)
        #expect(added == 0, "Merging identical pairs must add nothing")
        #expect(try store.loadTerms().count == 2, "Merge must not duplicate existing pairs")
    }

    @Test func mergeImportedAddsOnlyNewPairs() throws {
        let (store, _) = try makeStore()
        try store.addTerm(DictionaryTerm(phrase: "nbo", replacement: "NBO", source: "manual"))
        let added = try store.mergeImportedTerms([
            DictionaryTerm(phrase: "nbo", replacement: "NBO", source: "csv_import"),
            DictionaryTerm(phrase: "cloud", replacement: "Claude", source: "csv_import")
        ])
        #expect(added == 1, "Only the new pair is added")
        #expect(try store.loadTerms().count == 2, "Store ends with both unique pairs")
    }
}
