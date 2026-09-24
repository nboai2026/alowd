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
    /// A run this long with no sentence end closes at the next comma or
    /// semicolon, so one unpunctuated ramble can't become a last chunk that
    /// takes several seconds to rewrite after stop.
    public static let maximumChunkLength = 240

    public static func chunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for sentence in sentences(text) {
            current = current.isEmpty ? sentence : current + " " + sentence
            if current.count >= minimumChunkLength, sentence.last.map({ ".!?…,;".contains($0) }) ?? false {
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
    /// Past `maximumChunkLength` a comma or semicolon ends one too. Each
    /// decision depends only on the words before it, which is what keeps the
    /// split prefix-stable.
    static func sentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for word in text.split(whereSeparator: \.isWhitespace) {
            current = current.isEmpty ? String(word) : current + " " + word
            guard let last = word.last else { continue }
            if ".!?…".contains(last) || (",;".contains(last) && current.count >= maximumChunkLength) {
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
    /// Set once the final rewrite starts. From then on a prefetch still in
    /// flight from recording must not cancel anything: the final rewrite may
    /// be awaiting exactly the chunk it would cancel.
    private var isFinishing = false

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
        guard !isFinishing else { return }
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
        isFinishing = true
        var parts: [String] = []
        for chunk in chunks {
            guard let task = rewrites[chunk] else { continue }
            do {
                parts.append(try await task.value)
            } catch where !Task.isCancelled {
                // The chunk's own request was cancelled or failed; the
                // dictation itself was not, and must not be lost for it.
                // Retried through the queue, which keeps requests one at a time.
                rewrites[chunk] = nil
                enqueue(chunk)
                guard let retry = rewrites[chunk] else { continue }
                parts.append(try await retry.value)
            }
        }
        return parts.joined(separator: " ")
    }

    private func input(for chunk: String) -> PostProcessingInput {
        PostProcessingInput(rawText: chunk, mode: mode, dictionary: dictionary, snippets: snippets, language: language)
    }

    private func enqueue(_ chunk: String) {
        let previous = queueTail
        let processor = self.processor
        let input = input(for: chunk)
        let task = Task { () throws -> String in
            await previous?.value
            try Task.checkCancellation()
            return try await processor.process(input)
        }
        rewrites[chunk] = task
        queueTail = Task { _ = try? await task.value }
    }
}
