import Foundation

public final class DictationPipeline: Sendable {
    /// Exposed so the live-partials path can reuse the loaded engine instead
    /// of loading a second model.
    public let engine: TranscriptionEngine
    public let processor: PostProcessor
    private let inserter: TextInserter
    /// The processor is slow enough (a local LLM) that the transcript should be
    /// rewritten in chunks as it streams in, rather than whole after stop.
    public let rewritesIncrementally: Bool

    public init(
        engine: TranscriptionEngine,
        processor: PostProcessor,
        inserter: TextInserter,
        rewritesIncrementally: Bool = false
    ) {
        self.engine = engine
        self.processor = processor
        self.inserter = inserter
        self.rewritesIncrementally = rewritesIncrementally
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
        let finalText = try await process(transcript, mode: mode, dictionary: dictionary, snippets: snippets)
        let timing = DictationTiming(
            transcribeSeconds: processStart.timeIntervalSince(transcribeStart),
            postProcessSeconds: Date().timeIntervalSince(processStart)
        )
        return ((transcript.text, finalText), timing, transcript.language)
    }

    /// Post-processes a finished transcript. With a `rewriter` the text is
    /// rewritten chunk by chunk, reusing whatever it already rewrote while the
    /// user was talking.
    public func process(
        _ transcript: TranscriptResult,
        mode: WritingMode,
        dictionary: [DictionaryTerm],
        snippets: [Snippet],
        rewriter: IncrementalRewriter? = nil
    ) async throws -> String {
        if let rewriter, mode != .raw {
            return try await rewriter.rewrite(transcript.text)
        }
        return try await processor.process(PostProcessingInput(
            rawText: transcript.text,
            mode: mode,
            dictionary: dictionary,
            snippets: snippets,
            language: transcript.language
        ))
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

/// How long each stage of a dictation took, counted from the stop press:
/// work done while the user was still talking is not part of the wait.
public struct DictationTiming: Equatable, Sendable {
    public let transcribeSeconds: TimeInterval
    public let postProcessSeconds: TimeInterval
    /// Stop press to text pasted — the wait the user actually experiences.
    public let stopToInsertSeconds: TimeInterval?

    public init(transcribeSeconds: TimeInterval, postProcessSeconds: TimeInterval, stopToInsertSeconds: TimeInterval? = nil) {
        self.transcribeSeconds = transcribeSeconds
        self.postProcessSeconds = postProcessSeconds
        self.stopToInsertSeconds = stopToInsertSeconds
    }

    /// Compact summary for the menu status line, e.g. "1.2s + 16.9s rewrite",
    /// or "0.9s after stop: 0.3s + 0.5s rewrite" once the total is known. The
    /// rewrite is only worth naming when it is a real share of the wait.
    public var summary: String {
        var stages = String(format: "%.1fs", transcribeSeconds)
        if postProcessSeconds >= 0.5 {
            stages += String(format: " + %.1fs rewrite", postProcessSeconds)
        }
        guard let stopToInsertSeconds else { return stages }
        return String(format: "%.1fs after stop: ", stopToInsertSeconds) + stages
    }

    func withStopToInsert(_ seconds: TimeInterval) -> DictationTiming {
        DictationTiming(transcribeSeconds: transcribeSeconds, postProcessSeconds: postProcessSeconds, stopToInsertSeconds: seconds)
    }
}
