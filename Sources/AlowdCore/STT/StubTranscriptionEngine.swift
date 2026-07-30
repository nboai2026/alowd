import Foundation

public final class StubTranscriptionEngine: TranscriptionEngine {
    private let text: String
    private let confidence: Double

    public init(text: String, confidence: Double = 1.0) {
        self.text = text
        self.confidence = confidence
    }

    public func transcribe(audioFile: URL) async throws -> TranscriptResult {
        TranscriptResult(text: text, confidence: confidence)
    }
}
