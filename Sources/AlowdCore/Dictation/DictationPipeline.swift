import Foundation

public final class DictationPipeline: Sendable {
    /// Exposed so the live-partials path can reuse the loaded engine instead
    /// of loading a second model.
    public let engine: TranscriptionEngine
    private let processor: PostProcessor
    private let inserter: TextInserter

    public init(engine: TranscriptionEngine, processor: PostProcessor, inserter: TextInserter) {
        self.engine = engine
        self.processor = processor
        self.inserter = inserter
    }

    /// Transcribes and post-processes without inserting, so callers can persist
    /// the transcript before attempting insertion.
    public func produceText(
        audioFile: URL,
        mode: WritingMode,
        dictionary: [DictionaryTerm],
        snippets: [Snippet]
    ) async throws -> (rawText: String, finalText: String) {
        try await produceTextTimed(audioFile: audioFile, mode: mode, dictionary: dictionary, snippets: snippets).text
    }

    /// Same as `produceText`, also reporting where the time went. Post-processing
    /// with a large local model can dwarf transcription, and users need to be
    /// able to see that rather than guess.
    public func produceTextTimed(
        audioFile: URL,
        mode: WritingMode,
        dictionary: [DictionaryTerm],
        snippets: [Snippet]
    ) async throws -> (text: (rawText: String, finalText: String), timing: DictationTiming, language: String?) {
        // The engine and processor are not themselves cancellation-aware, so
        // check between stages: a cancel during transcription at least skips
        // the (often slower) rewrite instead of running the whole pipeline.
        try Task.checkCancellation()
        let transcribeStart = Date()
        let transcript = try await engine.transcribe(audioFile: audioFile)
        try Task.checkCancellation()
        let processStart = Date()
        let finalText = try await processor.process(PostProcessingInput(
            rawText: transcript.text,
            mode: mode,
            dictionary: dictionary,
            snippets: snippets
        ))
        let timing = DictationTiming(
            transcribeSeconds: processStart.timeIntervalSince(transcribeStart),
            postProcessSeconds: Date().timeIntervalSince(processStart)
        )
        return ((transcript.text, finalText), timing, transcript.language)
    }

    public func insert(_ text: String) throws {
        try inserter.insert(text)
    }

    @discardableResult
    public func finishDictation(
        audioFile: URL,
        mode: WritingMode,
        dictionary: [DictionaryTerm],
        snippets: [Snippet]
    ) async throws -> String {
        let (_, finalText) = try await produceText(
            audioFile: audioFile,
            mode: mode,
            dictionary: dictionary,
            snippets: snippets
        )
        try insert(finalText)
        return finalText
    }
}

/// How long each stage of a dictation took.
public struct DictationTiming: Equatable, Sendable {
    public let transcribeSeconds: TimeInterval
    public let postProcessSeconds: TimeInterval

    public init(transcribeSeconds: TimeInterval, postProcessSeconds: TimeInterval) {
        self.transcribeSeconds = transcribeSeconds
        self.postProcessSeconds = postProcessSeconds
    }

    /// Compact summary for the menu status line, e.g. "1.2s + 16.9s rewrite".
    /// The rewrite is only worth naming when it is a real share of the wait.
    public var summary: String {
        let transcribe = String(format: "%.1fs", transcribeSeconds)
        guard postProcessSeconds >= 0.5 else { return transcribe }
        return transcribe + String(format: " + %.1fs rewrite", postProcessSeconds)
    }
}
