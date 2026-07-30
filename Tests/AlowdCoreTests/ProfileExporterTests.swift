import Foundation
import Testing
@testable import AlowdCore

struct ProfileExporterTests {
    @Test func exportCopiesProfileWithoutSecrets() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        let store = ProfileStore(root: source)
        try store.bootstrap()
        try "secret_token=do-not-copy".write(
            to: source.appendingPathComponent("config/local-secrets.env"),
            atomically: true,
            encoding: .utf8
        )
        try "[{\"transcript\": \"private\"}]".write(
            to: source.appendingPathComponent("data/history.json"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("audio"),
            withIntermediateDirectories: true
        )
        try Data("wav".utf8).write(to: source.appendingPathComponent("audio/take.wav"))

        let exporter = ProfileExporter()
        try exporter.exportProfile(from: source, to: destination)

        #expect(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("config/settings.json").path),
            "Export must copy settings"
        )
        #expect(
            !FileManager.default.fileExists(atPath: destination.appendingPathComponent("config/local-secrets.env").path),
            "Export must skip secrets"
        )
        #expect(
            !FileManager.default.fileExists(atPath: destination.appendingPathComponent("data/history.json").path),
            "Export must not include dictation history"
        )
        #expect(
            !FileManager.default.fileExists(atPath: destination.appendingPathComponent("audio").path),
            "Export must not include retained audio"
        )
    }
}
