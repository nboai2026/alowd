import Foundation
@preconcurrency
import WhisperKit

public struct WhisperKitModelStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case missing
        case incomplete
        case ready
    }

    public let state: State
    public let modelFolder: URL?
    public let message: String

    public var isReady: Bool {
        state == .ready
    }
}

/// Keeps WhisperKit downloads and validation inside Alowd's local profile.
///
/// WhisperKit stores Hub snapshots below the supplied download root. The app must
/// load the concrete model directory inside that snapshot, not the root itself.
/// A WhisperKit model variant Alowd offers in its picker.
///
/// `id` is the stable value stored in `AppSettings.modelVariant`;
/// `whisperKitName` is the name handed to `WhisperKit.download`, whose Hub
/// snapshot folder is named "openai_whisper-<whisperKitName>".
public struct WhisperKitModelVariant: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let whisperKitName: String

    public init(id: String, displayName: String, whisperKitName: String) {
        self.id = id
        self.displayName = displayName
        self.whisperKitName = whisperKitName
    }

    public static let base = WhisperKitModelVariant(
        id: "base", displayName: "Base (fast, ~150 MB)", whisperKitName: "base"
    )
    public static let small = WhisperKitModelVariant(
        id: "small", displayName: "Small (balanced, ~500 MB)", whisperKitName: "small"
    )
    public static let largeV3Turbo = WhisperKitModelVariant(
        id: "large-v3-turbo", displayName: "Large v3 Turbo (best, ~1.6 GB)", whisperKitName: "large-v3_turbo"
    )

    public static let supported: [WhisperKitModelVariant] = [.base, .small, .largeV3Turbo]

    /// Resolves a settings value to a known variant, falling back to base so an
    /// edited settings.json never leaves the app without a usable variant.
    public static func named(_ id: String) -> WhisperKitModelVariant {
        supported.first { $0.id == id } ?? .base
    }

    /// Folder names this variant's installed snapshot may use.
    var installedFolderNames: [String] {
        ["openai_whisper-\(whisperKitName)", whisperKitName]
    }
}

public enum WhisperKitModelManager {
    public static let recommendedVariant = "base"

    /// Variant-aware status: only an installed snapshot of this exact variant
    /// (not just any model under the root) counts as ready.
    public static func status(in root: URL, variant: WhisperKitModelVariant) -> WhisperKitModelStatus {
        guard let modelFolder = installedModelFolder(in: root, variant: variant) else {
            return WhisperKitModelStatus(
                state: .missing,
                modelFolder: nil,
                message: "The \(variant.displayName) WhisperKit model is not installed."
            )
        }
        guard containsTokenizer(in: root) else {
            return WhisperKitModelStatus(
                state: .incomplete,
                modelFolder: nil,
                message: "The \(variant.displayName) WhisperKit model is missing its local tokenizer. Install it again."
            )
        }
        return WhisperKitModelStatus(
            state: .ready,
            modelFolder: modelFolder,
            message: "Local WhisperKit model ready (\(variant.displayName))."
        )
    }

    /// The installed snapshot folder for one specific variant, or nil.
    public static func installedModelFolder(in root: URL, variant: WhisperKitModelVariant) -> URL? {
        allModelFolderCandidates(in: root)
            .filter { variant.installedFolderNames.contains($0.lastPathComponent) }
            .sorted { $0.path.count < $1.path.count }
            .first(where: containsRequiredModelFiles)
    }

    public static func status(in root: URL) -> WhisperKitModelStatus {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return WhisperKitModelStatus(
                state: .missing,
                modelFolder: nil,
                message: "No local WhisperKit model is installed."
            )
        }

        if let modelFolder = installedModelFolder(in: root) {
            guard containsTokenizer(in: root) else {
                return WhisperKitModelStatus(
                    state: .incomplete,
                    modelFolder: nil,
                    message: "WhisperKit model is missing its local tokenizer. Install the recommended model again."
                )
            }
            return WhisperKitModelStatus(
                state: .ready,
                modelFolder: modelFolder,
                message: "Local WhisperKit model ready."
            )
        }

        let hasContents = ((try? FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty) == false)
        return WhisperKitModelStatus(
            state: hasContents ? .incomplete : .missing,
            modelFolder: nil,
            message: hasContents
                ? "WhisperKit model files are incomplete. Install the recommended model again."
                : "No local WhisperKit model is installed."
        )
    }

    public static func installedModelFolder(in root: URL) -> URL? {
        allModelFolderCandidates(in: root)
            .sorted { $0.path.count < $1.path.count }
            .first(where: containsRequiredModelFiles)
    }

    private static func allModelFolderCandidates(in root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        var candidates = [root]
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            while let url = enumerator.nextObject() as? URL {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    candidates.append(url)
                }
            }
        }
        return candidates
    }

    /// Downloads and loads the model once so a failed or partial download is not
    /// reported as ready. This is deliberately user-triggered; normal dictation
    /// remains local-only and never starts a download.
    @discardableResult
    public static func installRecommended(
        in root: URL,
        progress: @escaping @Sendable (Double?) -> Void = { _ in }
    ) async throws -> URL {
        try await install(variant: .base, in: root, progress: progress)
    }

    @discardableResult
    public static func install(
        variant: WhisperKitModelVariant,
        in root: URL,
        progress: @escaping @Sendable (Double?) -> Void = { _ in }
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let modelFolder = try await WhisperKit.download(
            variant: variant.whisperKitName,
            downloadBase: root,
            progressCallback: { downloadProgress in
                let total = downloadProgress.totalUnitCount
                progress(total > 0 ? Double(downloadProgress.completedUnitCount) / Double(total) : nil)
            }
        )

        // Loading verifies the Core ML bundles and ensures the tokenizer is stored
        // under Alowd's model root instead of depending on the CLI cache.
        _ = try await WhisperKit(
            modelFolder: modelFolder.path,
            tokenizerFolder: root,
            verbose: false,
            load: true,
            download: false
        )

        guard containsRequiredModelFiles(in: modelFolder) else {
            throw WhisperKitModelManagerError.invalidDownloadedModel(modelFolder)
        }
        return modelFolder
    }

    private static func containsRequiredModelFiles(in folder: URL) -> Bool {
        ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { name in
            let compiled = folder.appendingPathComponent("\(name).mlmodelc")
            let package = folder
                .appendingPathComponent("\(name).mlpackage")
                .appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
            return FileManager.default.fileExists(atPath: compiled.path)
                || FileManager.default.fileExists(atPath: package.path)
        }
    }

    private static func containsTokenizer(in root: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent == "tokenizer.json" {
                return true
            }
        }
        return false
    }
}

public enum WhisperKitModelManagerError: Error, LocalizedError {
    case invalidDownloadedModel(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidDownloadedModel(let folder):
            "WhisperKit finished downloading, but its model files are incomplete at \(folder.path)."
        }
    }
}
