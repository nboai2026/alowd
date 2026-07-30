import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AlowdCore

/// Menu-bar entry point for the Dictionary window, with a pending-suggestions
/// badge ("Dictionary... (3 new)").
struct DictionaryMenuItem: View {
    @ObservedObject var autoLearn: AutoLearnController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(autoLearn.pendingCount > 0 ? "Dictionary... (\(autoLearn.pendingCount) new)" : "Dictionary...") {
            openWindow(id: DictionaryWindowID.value)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

enum DictionaryWindowID {
    static let value = "dictionary"
}

@MainActor
final class DictionaryWindowModel: ObservableObject {
    @Published private(set) var terms: [DictionaryTerm] = []
    @Published private(set) var suggestions: [DictionarySuggestion] = []
    @Published private(set) var snippets: [Snippet] = []
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var isImporting = false
    @Published var isExporting = false

    private let store: DictionaryStore
    private let profileStore: ProfileStore

    init(store: DictionaryStore, profileStore: ProfileStore) {
        self.store = store
        self.profileStore = profileStore
    }

    convenience init() {
        let profileStore = ProfileStore()
        self.init(store: DictionaryStore(root: profileStore.root), profileStore: profileStore)
    }

    func reload() {
        do {
            try profileStore.bootstrap()
            terms = try store.loadTerms().sorted { $0.replacement.localizedCaseInsensitiveCompare($1.replacement) == .orderedAscending }
            suggestions = try store.loadSuggestions()
            snippets = try profileStore.loadSnippets()
            errorMessage = nil
        } catch {
            errorMessage = "Could not load the dictionary: \(error.localizedDescription)"
        }
    }

    // MARK: - Terms

    func addTerm(word: String, misspelling: String) {
        let word = word.trimmingCharacters(in: .whitespaces)
        let misspelling = misspelling.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        perform {
            try store.addTerm(DictionaryTerm(
                phrase: misspelling.isEmpty ? word.lowercased() : misspelling,
                replacement: word,
                source: "manual"
            ))
        }
    }

    func updateTerm(_ term: DictionaryTerm, word: String, misspelling: String) {
        let word = word.trimmingCharacters(in: .whitespaces)
        let misspelling = misspelling.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        var updated = term
        updated.replacement = word
        updated.phrase = misspelling.isEmpty ? word.lowercased() : misspelling
        guard updated != term else { return }
        perform { try store.updateTerm(updated) }
    }

    func deleteTerm(_ term: DictionaryTerm) {
        perform { try store.deleteTerm(id: term.id) }
    }

    // MARK: - Suggestions inbox

    func accept(_ suggestion: DictionarySuggestion) {
        perform { try store.acceptSuggestion(id: suggestion.id) }
        notifySuggestionsChanged()
    }

    func reject(_ suggestion: DictionarySuggestion) {
        perform { try store.rejectSuggestion(id: suggestion.id) }
        notifySuggestionsChanged()
    }

    // MARK: - Snippets

    func addSnippet(trigger: String, expansion: String) {
        let trigger = trigger.trimmingCharacters(in: .whitespaces)
        guard !trigger.isEmpty, !expansion.isEmpty else { return }
        saveSnippets(snippets + [Snippet(trigger: trigger, expansion: expansion)])
    }

    func updateSnippet(_ snippet: Snippet, trigger: String, expansion: String) {
        let trigger = trigger.trimmingCharacters(in: .whitespaces)
        guard !trigger.isEmpty, !expansion.isEmpty else { return }
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        var updated = snippets
        updated[index].trigger = trigger
        updated[index].expansion = expansion
        guard updated != snippets else { return }
        saveSnippets(updated)
    }

    func deleteSnippet(_ snippet: Snippet) {
        saveSnippets(snippets.filter { $0.id != snippet.id })
    }

    private func saveSnippets(_ snippets: [Snippet]) {
        perform { try profileStore.saveSnippets(snippets) }
    }

    // MARK: - CSV

    var exportDocument: DictionaryCSVDocument {
        DictionaryCSVDocument(text: DictionaryStore.exportCSV(terms))
    }

    func importCSV(from url: URL) {
        let didScope = url.startAccessingSecurityScopedResource()
        defer {
            if didScope { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let added = try store.mergeImportedTerms(DictionaryStore.importCSV(text))
            statusMessage = added == 1 ? "Imported 1 term." : "Imported \(added) terms."
            reload()
        } catch {
            errorMessage = "CSV import failed: \(error.localizedDescription)"
        }
    }

    func finishExport(result: Result<URL, Error>) {
        switch result {
        case .success:
            statusMessage = "Exported \(terms.count) terms."
        case .failure(let error):
            errorMessage = "CSV export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func perform(_ change: () throws -> Void) {
        do {
            try change()
            errorMessage = nil
            reload()
        } catch {
            errorMessage = "Could not save the change: \(error.localizedDescription)"
        }
    }

    private func notifySuggestionsChanged() {
        NotificationCenter.default.post(name: .alowdDictionarySuggestionsChanged, object: nil)
    }
}

struct DictionaryCSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct DictionaryView: View {
    @ObservedObject var model: DictionaryWindowModel

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            TabView {
                DictionaryTermsTab(model: model)
                    .tabItem { Text("Terms") }
                DictionarySuggestionsTab(model: model)
                    .tabItem {
                        Text(model.suggestions.isEmpty ? "Suggestions" : "Suggestions (\(model.suggestions.count))")
                    }
                DictionarySnippetsTab(model: model)
                    .tabItem { Text("Snippets") }
            }
            .padding()

            if let statusMessage = model.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.isImporting = true
                } label: {
                    Label("Import CSV", systemImage: "square.and.arrow.down")
                }
                .help("Import word,misspelling CSV (Wispr Flow / superwhisper format)")
                Button {
                    model.isExporting = true
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(model.terms.isEmpty)
                .help("Export the dictionary as word,misspelling CSV")
            }
        }
        .fileImporter(
            isPresented: $model.isImporting,
            allowedContentTypes: [.commaSeparatedText, .plainText]
        ) { result in
            if case .success(let url) = result {
                model.importCSV(from: url)
            }
        }
        .fileExporter(
            isPresented: $model.isExporting,
            document: model.exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "alowd-dictionary"
        ) { result in
            model.finishExport(result: result)
        }
        .onAppear {
            model.reload()
        }
    }
}

// MARK: - Terms tab

private struct DictionaryTermsTab: View {
    @ObservedObject var model: DictionaryWindowModel
    @State private var newWord = ""
    @State private var newMisspelling = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Word or phrase (e.g. WhisperKit)", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                TextField("Misspelling to correct (optional)", text: $newMisspelling)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    model.addTerm(word: newWord, misspelling: newMisspelling)
                    newWord = ""
                    newMisspelling = ""
                }
                .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if model.terms.isEmpty {
                Spacer()
                Text("No dictionary terms yet. Add words Alowd keeps misspelling.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(model.terms) { term in
                    DictionaryTermRow(model: model, term: term)
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct DictionaryTermRow: View {
    @ObservedObject var model: DictionaryWindowModel
    let term: DictionaryTerm
    @State private var word: String
    @State private var misspelling: String

    init(model: DictionaryWindowModel, term: DictionaryTerm) {
        self.model = model
        self.term = term
        _word = State(initialValue: term.replacement)
        _misspelling = State(initialValue: term.phrase == term.replacement.lowercased() ? "" : term.phrase)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("Word", text: $word, onCommit: commit)
                .textFieldStyle(.plain)
            TextField("Misspelling", text: $misspelling, onCommit: commit)
                .textFieldStyle(.plain)
                .foregroundStyle(.secondary)
            Text(term.source)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button(role: .destructive) {
                model.deleteTerm(term)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this term")
        }
        .padding(.vertical, 2)
    }

    private func commit() {
        model.updateTerm(term, word: word, misspelling: misspelling)
    }
}

// MARK: - Suggestions tab

private struct DictionarySuggestionsTab: View {
    @ObservedObject var model: DictionaryWindowModel

    var body: some View {
        if model.suggestions.isEmpty {
            VStack {
                Spacer()
                Text("No pending suggestions.")
                    .foregroundStyle(.secondary)
                Text("After you correct a pasted dictation, Alowd proposes the words it should learn here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
        } else {
            List(model.suggestions) { suggestion in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.replacement)
                            .fontWeight(.medium)
                        if suggestion.phrase != suggestion.replacement.lowercased() {
                            Text("corrects \"\(suggestion.phrase)\"")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(suggestion.source)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button("Accept") {
                        model.accept(suggestion)
                    }
                    Button("Reject", role: .destructive) {
                        model.reject(suggestion)
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
        }
    }
}

// MARK: - Snippets tab

private struct DictionarySnippetsTab: View {
    @ObservedObject var model: DictionaryWindowModel
    @State private var newTrigger = ""
    @State private var newExpansion = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Spoken trigger (e.g. calendar link)", text: $newTrigger)
                    .textFieldStyle(.roundedBorder)
                TextField("Expands to", text: $newExpansion)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    model.addSnippet(trigger: newTrigger, expansion: newExpansion)
                    newTrigger = ""
                    newExpansion = ""
                }
                .disabled(
                    newTrigger.trimmingCharacters(in: .whitespaces).isEmpty
                        || newExpansion.isEmpty
                )
            }

            if model.snippets.isEmpty {
                Spacer()
                Text("No snippets yet. Say a trigger while dictating and Alowd expands it.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(model.snippets) { snippet in
                    DictionarySnippetRow(model: model, snippet: snippet)
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct DictionarySnippetRow: View {
    @ObservedObject var model: DictionaryWindowModel
    let snippet: Snippet
    @State private var trigger: String
    @State private var expansion: String

    init(model: DictionaryWindowModel, snippet: Snippet) {
        self.model = model
        self.snippet = snippet
        _trigger = State(initialValue: snippet.trigger)
        _expansion = State(initialValue: snippet.expansion)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("Trigger", text: $trigger, onCommit: commit)
                .textFieldStyle(.plain)
            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
            TextField("Expansion", text: $expansion, onCommit: commit)
                .textFieldStyle(.plain)
                .foregroundStyle(.secondary)
            Button(role: .destructive) {
                model.deleteSnippet(snippet)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this snippet")
        }
        .padding(.vertical, 2)
    }

    private func commit() {
        model.updateSnippet(snippet, trigger: trigger, expansion: expansion)
    }
}
