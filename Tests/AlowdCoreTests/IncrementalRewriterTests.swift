import Foundation
import Testing
@testable import AlowdCore

struct RewriteChunkerTests {
    @Test func splitsAtSentenceEnds() {
        let text = "This first sentence is comfortably long enough to stand alone. And the second one is long enough to stand on its own too."
        #expect(RewriteChunker.chunks(text) == [
            "This first sentence is comfortably long enough to stand alone.",
            "And the second one is long enough to stand on its own too.",
        ])
    }

    @Test func shortSentencesNeverReachTheModelAlone() {
        // A chat model handed a bare "Okay." tends to reply to it.
        let chunks = RewriteChunker.chunks("Okay. Yeah. So the deploy went out on Tuesday and nobody noticed anything wrong.")
        #expect(chunks == ["Okay. Yeah. So the deploy went out on Tuesday and nobody noticed anything wrong."])
    }

    @Test func closedChunksNeverChangeAsMoreSpeechArrives() {
        // The whole incremental rewrite rests on this: a chunk rewritten while
        // the user was talking must be exactly a chunk of the final text.
        let final = "Um so the first thing I wanted to say is that the build is green again. "
            + "The second thing is that we should ship on Thursday. Right. "
            + "And then the last thing is the docs, which still mention the old flag, and that needs a fix. "
            + String(repeating: "and then we kept going without ever stopping the sentence, ", count: 8)
            + "until the end."
        let words = final.split(separator: " ")
        let finalChunks = RewriteChunker.chunks(final)
        for length in 1...words.count {
            let prefix = words.prefix(length).joined(separator: " ")
            let closed = RewriteChunker.closedChunks(prefix)
            #expect(Array(finalChunks.prefix(closed.count)) == closed, "Prefix of \(length) words changed a closed chunk")
        }
    }

    @Test func anUnpunctuatedRambleClosesAtACommaOnceItIsLong() {
        // Otherwise the whole ramble is one open chunk, rewritten after stop.
        let ramble = String(repeating: "and then we kept going without ever stopping the sentence, ", count: 10)
        let chunks = RewriteChunker.chunks(ramble)
        #expect(chunks.count > 1)
        #expect(chunks.dropLast().allSatisfy { $0.count <= RewriteChunker.maximumChunkLength + 80 })
    }

    @Test func emptyTextHasNoChunks() {
        #expect(RewriteChunker.chunks("   ").isEmpty)
    }
}

struct IncrementalRewriterTests {
    private let first = "This first sentence is comfortably long enough to stand alone."
    private let second = "And the second one is long enough to stand on its own too."

    private func makeRewriter(_ processor: RecordingProcessor) -> IncrementalRewriter {
        IncrementalRewriter(processor: processor, mode: .myVoiceCasual, dictionary: [], snippets: [], language: "en")
    }

    @Test func rewritesEachChunkAndJoinsThemInOrder() async throws {
        let processor = RecordingProcessor()
        let result = try await makeRewriter(processor).rewrite("\(first) \(second)")
        #expect(result == "[\(first)] [\(second)]")
    }

    @Test func prefetchedChunksAreNotRewrittenAgain() async throws {
        let processor = RecordingProcessor()
        let rewriter = makeRewriter(processor)
        await rewriter.prefetch([first])
        _ = try await rewriter.rewrite("\(first) \(second)")
        #expect(processor.inputs == [first, second], "Stop must only pay for the chunk it has not seen")
    }

    @Test func requestsRunOneAtATimeInOrder() async throws {
        let processor = RecordingProcessor(delay: 0.02)
        let rewriter = makeRewriter(processor)
        await rewriter.prefetch([first, second])
        _ = try await rewriter.rewrite("\(first) \(second)")
        #expect(processor.maximumConcurrency == 1)
        #expect(processor.inputs == [first, second])
    }

    @Test func speculationOnTextThatDidNotSurviveIsCancelled() async throws {
        // The speaker paused mid-thought (the open chunk was rewritten on
        // spec), then carried on: that chunk no longer exists.
        let processor = RecordingProcessor(delay: 0.2)
        let rewriter = makeRewriter(processor)
        let abandoned = "And the second one is long enough"
        await rewriter.prefetch([first, abandoned])
        let result = try await rewriter.rewrite("\(first) \(second)")
        #expect(result == "[\(first)] [\(second)]")
        #expect(!processor.completed.contains(abandoned), "Stale speculation must not run to completion ahead of real work")
    }

    @Test func aWrongGuessStopsHoldingUpTheQueueAsSoonAsItIsSuperseded() async throws {
        // Paused, so the unfinished chunk was rewritten on spec; then the
        // speaker carried on and the chunk grew. The guess must go at once,
        // not linger in the serial queue until stop.
        let processor = RecordingProcessor(delay: 0.2)
        let rewriter = makeRewriter(processor)
        let guess = "And the second one is long enough"
        await rewriter.prefetch([first])
        await rewriter.prefetch([first, guess], speculative: true)
        await rewriter.prefetch([first])
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(!processor.completed.contains(guess))
    }

    /// Regression: a prefetch scheduled during recording can reach the actor
    /// after the final rewrite has started. It used to cancel the chunk the
    /// rewrite was awaiting, which threw CancellationError, and the whole
    /// dictation was discarded as "cancelled".
    @Test func aLatePrefetchCannotCancelWhatTheFinalRewriteNeeds() async throws {
        let processor = RecordingProcessor(delay: 0.1)
        let rewriter = makeRewriter(processor)
        await rewriter.prefetch([first, second], speculative: true)
        async let result = rewriter.rewrite("\(first) \(second)")
        try await Task.sleep(nanoseconds: 20_000_000)
        await rewriter.prefetch([first])
        #expect(try await result == "[\(first)] [\(second)]")
    }

    @Test func aChunkWhoseRequestFailedIsRetriedNotLost() async throws {
        let processor = FlakyProcessor(failures: 1)
        let rewriter = IncrementalRewriter(processor: processor, mode: .myVoiceCasual, dictionary: [], snippets: [], language: nil)
        #expect(try await rewriter.rewrite(first) == "ok")
    }

    @Test func aRetryWaitsItsTurnInTheQueue() async throws {
        // Codex review: retrying outside the queue ran two requests at once.
        let processor = FlakyProcessor(failures: 1, delay: 0.05)
        let rewriter = IncrementalRewriter(processor: processor, mode: .myVoiceCasual, dictionary: [], snippets: [], language: nil)
        _ = try await rewriter.rewrite("\(first) \(second)")
        #expect(processor.maximumConcurrency == 1)
    }

    @Test func carriesModeAndLanguageToEveryChunk() async throws {
        let processor = RecordingProcessor()
        let rewriter = IncrementalRewriter(processor: processor, mode: .myVoicePro, dictionary: [], snippets: [], language: "fr")
        _ = try await rewriter.rewrite(first)
        #expect(processor.modes == [.myVoicePro])
        #expect(processor.languages == ["fr"])
    }
}

/// Wraps each chunk in brackets so joins are visible, and records what it saw.
final class RecordingProcessor: PostProcessor, @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private var active = 0
    private(set) var maximumConcurrency = 0
    private var _inputs: [String] = []
    private var _completed: [String] = []
    private var _modes: [WritingMode] = []
    private var _languages: [String?] = []

    init(delay: TimeInterval = 0) {
        self.delay = delay
    }

    var inputs: [String] { lock.withLock { _inputs } }
    var completed: [String] { lock.withLock { _completed } }
    var modes: [WritingMode] { lock.withLock { _modes } }
    var languages: [String?] { lock.withLock { _languages } }

    func process(_ input: PostProcessingInput) async throws -> String {
        lock.withLock {
            _inputs.append(input.rawText)
            _modes.append(input.mode)
            _languages.append(input.language)
            active += 1
            maximumConcurrency = max(maximumConcurrency, active)
        }
        defer { lock.withLock { active -= 1 } }
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        lock.withLock { _completed.append(input.rawText) }
        return "[\(input.rawText)]"
    }
}

final class FlakyProcessor: PostProcessor, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: Int
    private let delay: TimeInterval
    private var active = 0
    private(set) var maximumConcurrency = 0

    init(failures: Int, delay: TimeInterval = 0) {
        self.failures = failures
        self.delay = delay
    }

    func process(_ input: PostProcessingInput) async throws -> String {
        let fail = lock.withLock { () -> Bool in
            active += 1
            maximumConcurrency = max(maximumConcurrency, active)
            guard failures > 0 else { return false }
            failures -= 1
            return true
        }
        defer { lock.withLock { active -= 1 } }
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if fail { throw CancellationError() }
        return "ok"
    }
}
