import Foundation
import Testing
@testable import AlowdCore

struct ProfileStoreTests {
    @Test func bootstrapCreatesPortableDirectoryLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProfileStore(root: root)
        try store.bootstrap()

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("config").path), "Missing config directory")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("data").path), "Missing data directory")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("models/whisperkit").path), "Missing WhisperKit model directory")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("exports").path), "Missing exports directory")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("config/settings.json").path), "Missing settings file")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("data/dictionary.json").path), "Missing dictionary file")
    }

    @Test func loadSettingsOverridesStaleProfileDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProfileStore(root: root)
        try store.bootstrap()

        // Simulate a profile written before a rename/move: the file sits in
        // `root` but claims the profile lives somewhere that no longer exists.
        var stale = AppSettings.default
        stale.profileDirectory = URL(fileURLWithPath: "/Users/example/OldName", isDirectory: true)
        let raw = try AlowdJSONCoding.makeEncoder().encode(stale)
        try raw.write(to: root.appendingPathComponent("config/settings.json"))

        let loaded = try store.loadSettings()
        #expect(loaded.profileDirectory == root, "Store root must win over a stale persisted path")
    }

    @Test func saveSettingsStampsStoreRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProfileStore(root: root)
        try store.bootstrap()

        var settings = AppSettings.default
        settings.profileDirectory = URL(fileURLWithPath: "/Users/example/Elsewhere", isDirectory: true)
        try store.saveSettings(settings)

        #expect(try store.loadSettings().profileDirectory == root, "Saved settings must record the real root")
    }

    @Test func dictionaryRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProfileStore(root: root)
        try store.bootstrap()

        let terms = [DictionaryTerm(phrase: "nbo", replacement: "NBO", source: "test")]
        try store.saveDictionary(terms)
        let loaded = try store.loadDictionary()
        #expect(loaded == terms, "Dictionary terms must round trip")
    }

    @Test func legacyProfileDirectoryIsMovedToAlowd() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let legacy = container.appendingPathComponent(ProfileStore.legacyProfileDirectoryName, isDirectory: true)
        let new = container.appendingPathComponent("Alowd", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("config"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("config/settings.json"))

        ProfileStore.migrateLegacyProfileIfNeeded(legacyRoot: legacy, newRoot: new)

        #expect(!FileManager.default.fileExists(atPath: legacy.path), "Legacy profile directory must be moved away")
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("config/settings.json").path), "Profile contents must survive the move")
    }

    @Test func migrationSkipsWhenNewDirectoryAlreadyExists() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let legacy = container.appendingPathComponent(ProfileStore.legacyProfileDirectoryName, isDirectory: true)
        let new = container.appendingPathComponent("Alowd", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: new.appendingPathComponent("sentinel"))

        ProfileStore.migrateLegacyProfileIfNeeded(legacyRoot: legacy, newRoot: new)

        #expect(FileManager.default.fileExists(atPath: legacy.path), "Legacy directory must be left untouched when the new one exists")
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("sentinel").path), "Existing Alowd directory must not be replaced")
    }

    @Test func migrationSkipsWhenLegacyDirectoryMissing() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let new = container.appendingPathComponent("Alowd", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        ProfileStore.migrateLegacyProfileIfNeeded(legacyRoot: container.appendingPathComponent(ProfileStore.legacyProfileDirectoryName), newRoot: new)

        #expect(!FileManager.default.fileExists(atPath: new.path), "No Alowd directory should be created when there is nothing to migrate")
    }

    @Test func bootstrapMigratesSiblingLegacyDirectory() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let legacy = container.appendingPathComponent(ProfileStore.legacyProfileDirectoryName, isDirectory: true)
        let new = container.appendingPathComponent("Alowd", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("data"), withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: legacy.appendingPathComponent("data/dictionary.json"))

        try ProfileStore(root: new).bootstrap()

        #expect(!FileManager.default.fileExists(atPath: legacy.path), "bootstrap must migrate the legacy sibling directory")
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("data/dictionary.json").path), "Migrated data must be preserved")
    }
}
