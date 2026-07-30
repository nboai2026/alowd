import Foundation
import Testing
@testable import AlowdCore

struct WhisperKitModelManagerTests {
    @Test func reportsMissingModel() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let status = WhisperKitModelManager.status(in: root)
        #expect(status.state == .missing, "A missing model root must report missing")
        #expect(status.modelFolder == nil, "A missing model root must not resolve a folder")
    }

    @Test func findsNestedCompleteModel() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("models/snapshots/base", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try FileManager.default.createDirectory(
                at: model.appendingPathComponent("\(name).mlmodelc", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("tokenizer.json").path,
            contents: Data()
        )

        let status = WhisperKitModelManager.status(in: root)
        #expect(status.state == .ready, "A complete nested model must report ready")
        #expect(
            status.modelFolder?.standardizedFileURL.path == model.standardizedFileURL.path,
            "The manager must resolve the concrete model directory"
        )
    }

    @Test func reportsIncompleteModel() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("partial-model", isDirectory: true),
            withIntermediateDirectories: true
        )

        let status = WhisperKitModelManager.status(in: root)
        #expect(status.state == .incomplete, "Partial model files must not report ready")
    }

    @Test func variantStatusOnlyMatchesItsOwnSnapshot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeCompleteModel(in: root, folderName: "openai_whisper-base")

        let baseStatus = WhisperKitModelManager.status(in: root, variant: .base)
        #expect(baseStatus.state == .ready, "An installed base snapshot must report the base variant ready")
        #expect(
            baseStatus.modelFolder?.lastPathComponent == "openai_whisper-base",
            "The base variant must resolve its own snapshot folder"
        )

        let smallStatus = WhisperKitModelManager.status(in: root, variant: .small)
        #expect(smallStatus.state == .missing, "Another installed variant must not make small report ready")
    }

    @Test func variantStatusFindsLargeV3TurboSnapshot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeCompleteModel(in: root, folderName: "openai_whisper-large-v3_turbo")

        let status = WhisperKitModelManager.status(in: root, variant: .largeV3Turbo)
        #expect(status.state == .ready, "The large-v3-turbo snapshot folder must be recognized")
    }

    @Test func variantStatusRequiresTokenizer() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeCompleteModel(in: root, folderName: "openai_whisper-small", tokenizer: false)

        let status = WhisperKitModelManager.status(in: root, variant: .small)
        #expect(status.state == .incomplete, "A snapshot without a tokenizer must report incomplete")
    }

    @Test func unknownVariantNameFallsBackToBase() {
        #expect(WhisperKitModelVariant.named("no-such-model") == .base, "Unknown settings values must fall back to base")
        #expect(WhisperKitModelVariant.named("large-v3-turbo") == .largeV3Turbo, "Known ids must resolve exactly")
    }

    private func makeCompleteModel(in root: URL, folderName: String, tokenizer: Bool = true) throws {
        let model = root.appendingPathComponent("models/snapshots/\(folderName)", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try FileManager.default.createDirectory(
                at: model.appendingPathComponent("\(name).mlmodelc", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        if tokenizer {
            FileManager.default.createFile(
                atPath: root.appendingPathComponent("tokenizer.json").path,
                contents: Data()
            )
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alowd-model-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
