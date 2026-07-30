import Foundation

/// Copies the profile (settings, dictionary, snippets, prompts) for backup or
/// migration. Dictation history, retained audio, and anything secret-looking
/// are deliberately excluded: exports often land in cloud-synced folders, and
/// full transcripts leaving `~/Alowd` should never happen as a side effect.
public final class ProfileExporter: Sendable {
    public init() {}

    public func exportProfile(from source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try copyDirectory(source, to: destination)
    }

    private func copyDirectory(_ source: URL, to destination: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for item in contents {
            if shouldSkip(item) { continue }
            let target = destination.appendingPathComponent(item.lastPathComponent)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try copyDirectory(item, to: target)
            } else {
                try FileManager.default.copyItem(at: item, to: target)
            }
        }
    }

    private func shouldSkip(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name == "history.json" || name == "audio" || name == "exports" { return true }
        return name.contains("secret") || name.hasSuffix(".env") || name.contains("token") || name.contains("key")
    }
}
