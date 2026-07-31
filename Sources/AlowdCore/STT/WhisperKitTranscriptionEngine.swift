import Foundation
@preconcurrency
import WhisperKit

public final class WhisperKitTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    private let whisperKit: WhisperKit
    private let language: String?
    private let translateToEnglish: Bool
    /// The live-partials path and the final decode share this one WhisperKit
    /// instance, and overlapping decodes corrupt its state — see DecodeGate.
    private let gate = DecodeGate()

    public init(
        modelPath: URL,
        modelRoot: URL,
        language: String? = nil,
        translateToEnglish: Bool = false
    ) async throws {
        self.language = language
        self.translateToEnglish = translateToEnglish
        self.whisperKit = try await WhisperKit(
            modelFolder: modelPath.path,
            tokenizerFolder: modelRoot,
            verbose: false,
            load: true,
            download: false
        )
    }

    public func transcribe(audioFile: URL) async throws -> TranscriptResult {
        let whisperKit = self.whisperKit
        let options = decodingOptions()
        let decoded = try await gate.run {
            let results = try await whisperKit.transcribe(audioPath: audioFile.path, decodeOptions: options)
            return (
                text: results.map(\.text).joined(separator: " "),
                language: results.first?.language
            )
        }
        return TranscriptResult(text: decoded.text, confidence: 1.0, language: decoded.language)
    }

    private func decodingOptions() -> DecodingOptions {
        DecodingOptions(
            task: translateToEnglish ? .translate : .transcribe,
            language: language,
            detectLanguage: language == nil
        )
    }
}

extension WhisperKitTranscriptionEngine: LiveSampleTranscribing {
    /// Live partial decode path: same engine, same language/translate options,
    /// fed raw 16kHz mono samples accumulated during recording.
    public func transcribeLiveSamples(_ samples: [Float]) async throws -> String {
        let whisperKit = self.whisperKit
        let options = decodingOptions()
        // Skipped rather than queued when the final decode holds the model:
        // a partial that waited its turn is stale, and the batch result is
        // what actually gets inserted.
        let text = try await gate.runIfFree {
            let results: [TranscriptionResult] = try await whisperKit.transcribe(
                audioArray: samples,
                decodeOptions: options
            )
            return results.map(\.text).joined(separator: " ")
        }
        return text ?? ""
    }
}
