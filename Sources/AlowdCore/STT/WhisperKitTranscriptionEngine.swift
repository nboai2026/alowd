import Foundation
@preconcurrency
import WhisperKit

public final class WhisperKitTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    private let whisperKit: WhisperKit
    private let language: String?
    private let translateToEnglish: Bool

    public init(
        modelPath: URL,
        modelRoot: URL,
        language: String? = nil,
        translateToEnglish: Bool = true
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
        let results = try await whisperKit.transcribe(audioPath: audioFile.path, decodeOptions: decodingOptions())
        let text = results.map(\.text).joined(separator: " ")
        return TranscriptResult(text: text, confidence: 1.0)
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
        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: decodingOptions()
        )
        return results.map(\.text).joined(separator: " ")
    }
}
