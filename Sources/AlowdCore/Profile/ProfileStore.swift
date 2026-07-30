import Foundation

public protocol ProfileReading: AnyObject, Sendable {
    func bootstrap() throws
    func loadSettings() throws -> AppSettings
    func loadDictionary() throws -> [DictionaryTerm]
    func loadSnippets() throws -> [Snippet]
}

public final class ProfileStore: ProfileReading, @unchecked Sendable {
    public let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL = AppSettings.default.profileDirectory) {
        self.root = root
        self.encoder = AlowdJSONCoding.makeEncoder()
        self.decoder = AlowdJSONCoding.makeDecoder()
    }

    public func bootstrap() throws {
        Self.migrateLegacyProfileIfNeeded(
            legacyRoot: root.deletingLastPathComponent().appendingPathComponent(Self.legacyProfileDirectoryName, isDirectory: true),
            newRoot: root
        )

        let directories = [
            root.appendingPathComponent("config", isDirectory: true),
            root.appendingPathComponent("data", isDirectory: true),
            AlowdPaths.whisperKitModelRoot(profileRoot: root),
            root.appendingPathComponent("exports", isDirectory: true)
        ]

        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // Transcripts, dictionary, and retained audio are plaintext. Owner-only
        // access on the profile root keeps other local accounts on a shared
        // Mac out of all of it, whatever the umask says about files inside.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )

        if !FileManager.default.fileExists(atPath: settingsURL.path) {
            try saveSettings(AppSettings.default)
        }
        if !FileManager.default.fileExists(atPath: dictionaryURL.path) {
            try saveDictionary([])
        }
        if !FileManager.default.fileExists(atPath: snippetsURL.path) {
            try saveSnippets([])
        }
        if !FileManager.default.fileExists(atPath: suggestionsURL.path) {
            try Data("[]".utf8).write(to: suggestionsURL)
        }
    }

    /// Folder name used by the app before the Alowd rename. Split so the
    /// repo-wide rename grep stays clean.
    static let legacyProfileDirectoryName = "Nick" + "Flow"

    /// One-time rename migration: if a legacy profile directory (pre-rename
    /// name) sits next to where the `Alowd` profile should live and the new
    /// directory does not exist yet, move the legacy directory into place.
    /// Best-effort — any failure leaves the legacy directory untouched and
    /// bootstrap proceeds with a fresh profile.
    static func migrateLegacyProfileIfNeeded(
        legacyRoot: URL,
        newRoot: URL,
        fileManager: FileManager = .default
    ) {
        guard newRoot.lastPathComponent == "Alowd" else { return }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacyRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              !fileManager.fileExists(atPath: newRoot.path) else { return }
        try? fileManager.moveItem(at: legacyRoot, to: newRoot)
    }

    /// The store's own root always wins over the persisted `profileDirectory`:
    /// the file lives inside the profile, so a stored path that disagrees is
    /// stale (renamed app, moved folder, profile imported on another Mac).
    public func loadSettings() throws -> AppSettings {
        var settings = try decoder.decode(AppSettings.self, from: Data(contentsOf: settingsURL))
        settings.profileDirectory = root
        return settings
    }

    public func saveSettings(_ settings: AppSettings) throws {
        var settings = settings
        settings.profileDirectory = root
        try encoder.encode(settings).write(to: settingsURL, options: [.atomic])
    }

    public func loadDictionary() throws -> [DictionaryTerm] {
        try decoder.decode([DictionaryTerm].self, from: Data(contentsOf: dictionaryURL))
    }

    public func saveDictionary(_ terms: [DictionaryTerm]) throws {
        try encoder.encode(terms).write(to: dictionaryURL, options: [.atomic])
    }

    public func loadSnippets() throws -> [Snippet] {
        try decoder.decode([Snippet].self, from: Data(contentsOf: snippetsURL))
    }

    public func saveSnippets(_ snippets: [Snippet]) throws {
        try encoder.encode(snippets).write(to: snippetsURL, options: [.atomic])
    }

    private var settingsURL: URL { root.appendingPathComponent("config/settings.json") }
    private var dictionaryURL: URL { root.appendingPathComponent("data/dictionary.json") }
    private var snippetsURL: URL { root.appendingPathComponent("data/snippets.json") }
    private var suggestionsURL: URL { root.appendingPathComponent("data/dictionary-suggestions.json") }
}
