import Foundation

public struct TranscriptResult: Equatable, Sendable {
    public var text: String
    public var confidence: Double
    /// Language the engine actually decoded with (for example "fr"). Reported
    /// so auto-detect is visible: Whisper given the wrong language token
    /// translates instead of transcribing, and the user needs to see that
    /// happen rather than guess why English came out.
    public var language: String?

    public init(text: String, confidence: Double, language: String? = nil) {
        self.text = text
        self.confidence = confidence
        self.language = language
    }
}

public protocol TranscriptionEngine: Sendable {
    func transcribe(audioFile: URL) async throws -> TranscriptResult
}
