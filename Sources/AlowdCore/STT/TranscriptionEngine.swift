import Foundation

public struct TranscriptResult: Equatable, Sendable {
    public var text: String
    public var confidence: Double

    public init(text: String, confidence: Double) {
        self.text = text
        self.confidence = confidence
    }
}

public protocol TranscriptionEngine: Sendable {
    func transcribe(audioFile: URL) async throws -> TranscriptResult
}
