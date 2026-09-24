import Foundation

/// Splits a transcript into the pieces the rewrite model sees one at a time.
///
/// The split is prefix-stable: every chunk except the last ends a sentence and
/// is followed by another, so appending more speech can never change it. That
/// is what makes it safe to rewrite chunks while the user is still talking and
/// reuse the results once they stop.
public enum RewriteChunker {
    /// Sentences shorter than this are merged into the next one, so "Okay."
    /// never reaches the model on its own. Handed a bare interjection, a chat
    /// model tends to reply to it rather than rewrite it.
    public static let minimumChunkLength = 60

    public static func chunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for sentence in sentences(text) {
            current = current.isEmpty ? sentence : current + " " + sentence
            if current.count >= minimumChunkLength {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    /// The chunks of `text` that no further speech can change.
    public static func closedChunks(_ text: String) -> [String] {
        Array(chunks(text).dropLast())
    }

    /// Words up to and including one ending in terminal punctuation. Whisper
    /// punctuates its output, so this is where the speaker's sentences end.
    static func sentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for word in text.split(whereSeparator: \.isWhitespace) {
            current = current.isEmpty ? String(word) : current + " " + word
            if let last = word.last, ".!?…".contains(last) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            sentences.append(current)
        }
        return sentences
    }
}

/// Rewrites a transcript chunk by chunk, starting while the user is still
/// talking.
///
/// A whole-transcript rewrite cannot start until the user stops, and its cost
/// grows with every word: ~27 ms per output token on qwen3.6:35b, so a
/// 1,300-character dictation spent 7.8 s in the rewrite alone. Rewriting each
/// sentence as soon as it is final leaves only the last one for after stop.
///
/// Requests run one at a time, in the order they were asked for. Ollama
/// answers one at a time anyway, and queueing here is what lets a stale
/// speculative request be cancelled before it reaches the model.
public actor IncrementalRewriter {
    private let processor: PostProcessor
    private let mode: WritingMode
    private let dictionary: [DictionaryTerm]
    private let snippets: [Snippet]
    private let language: String?
    private var rewrites: [String: Task<String, Error>] = [:]
    /// Chunks requested on a guess (the unfinished last chunk, rewritten when
    /// the speaker paused). A later prefetch that no longer contains one
    /// cancels it, so a guess never holds up the queue once it is wrong.
    private var speculative: Set<String> = []
    private var queueTail: Task<Void, Never>?

    public init(
        processor: PostProcessor,
        mode: WritingMode,
        dictionary: [DictionaryTerm],
        snippets: [Snippet],
        language: String?
    ) {
        self.processor = processor
        self.mode = mode
        self.dictionary = dictionary
        self.snippets = snippets
        self.language = language
    }

    /// Starts rewriting whichever of `chunks` has not been started yet.
    ///
    /// - Parameter speculative: the last chunk is a guess that may still grow;
    ///   it is dropped as soon as a later prefetch disagrees.
    public func prefetch(_ chunks: [String], speculative isSpeculative: Bool = false) {
        let wanted = Set(chunks)
        for chunk in speculative where !wanted.contains(chunk) {
            rewrites.removeValue(forKey: chunk)?.cancel()
            speculative.remove(chunk)
        }
        for chunk in chunks where rewrites[chunk] == nil {
            enqueue(chunk)
        }
        if isSpeculative, let last = chunks.last {
            speculative.insert(last)
        }
    }

    /// The rewrite of the whole `text`: reuses every chunk already rewritten
    /// or in progress and requests only the rest.
    public func rewrite(_ text: String) async throws -> String {
        let chunks = RewriteChunker.chunks(text)
        // Speculation on text that did not survive (the speaker paused, then
        // carried on) must not hold up the chunks that are actually needed.
        let wanted = Set(chunks)
        for (chunk, task) in rewrites where !wanted.contains(chunk) {
            task.cancel()
            rewrites[chunk] = nil
        }
        speculative.removeAll()
        prefetch(chunks)
        var parts: [String] = []
        for chunk in chunks {
            guard let task = rewrites[chunk] else { continue }
            parts.append(try await task.value)
        }
        return parts.joined(separator: " ")
    }

    private func enqueue(_ chunk: String) {
        let previous = queueTail
        let processor = self.processor
        let input = PostProcessingInput(
            rawText: chunk,
            mode: mode,
            dictionary: dictionary,
            snippets: snippets,
            language: language
        )
        let task = Task { () throws -> String in
            await previous?.value
            try Task.checkCancellation()
            return try await processor.process(input)
        }
        rewrites[chunk] = task
        queueTail = Task { _ = try? await task.value }
    }
}
