import Foundation
import Testing
@testable import AlowdCore

struct StreamingTranscriptStateTests {
    private func segment(_ text: String, _ start: Int, _ end: Int) -> TimedSegment {
        TimedSegment(text: text, startSample: start, endSample: end)
    }

    @Test func confirmsEverySegmentButTheLast() {
        var state = StreamingTranscriptState()
        state.apply(
            [segment(" One.", 0, 10_000), segment(" Two.", 10_000, 20_000), segment(" Thr", 20_000, 38_000)],
            decodedFrom: 0, through: 40_000, isFinal: false
        )
        #expect(state.confirmed == ["One.", "Two."])
        #expect(state.pending == ["Thr"])
        #expect(state.confirmedEnd == 20_000, "The next decode starts where the last confirmed segment ended")
        #expect(state.text == "One. Two. Thr")
    }

    @Test func positionsAreAbsoluteAcrossDecodes() {
        var state = StreamingTranscriptState()
        state.apply([segment("A.", 0, 10_000), segment("B", 10_000, 30_000)], decodedFrom: 0, through: 32_000, isFinal: false)
        state.apply([segment("B.", 0, 12_000), segment("C", 12_000, 30_000)], decodedFrom: 10_000, through: 48_000, isFinal: false)
        #expect(state.confirmed == ["A.", "B."])
        #expect(state.confirmedEnd == 22_000)
        #expect(state.decodedThrough == 48_000)
    }

    @Test func neverConfirmsASegmentEndingAtTheEdgeOfTheAudio() {
        // A segment that ends right where the captured audio ends may be a
        // word cut off mid-syllable; the next decode sees the rest of it.
        var state = StreamingTranscriptState()
        let end = 40_000
        state.apply(
            [segment("One.", 0, 10_000), segment("Tw", 10_000, end - StreamingTranscriptState.edgeGuardSamples + 1), segment("o", 35_000, end)],
            decodedFrom: 0, through: end, isFinal: false
        )
        #expect(state.confirmed == ["One."])
        #expect(state.pending == ["Tw", "o"])
    }

    @Test func aFinalDecodeConfirmsEverything() {
        var state = StreamingTranscriptState()
        state.apply([segment("One.", 0, 10_000), segment("Two.", 10_000, 15_900)], decodedFrom: 0, through: 16_000, isFinal: true)
        #expect(state.confirmed == ["One.", "Two."])
        #expect(state.pending.isEmpty)
        #expect(state.confirmedEnd == 16_000)
    }

    @Test func confirmingPendingKeepsItsText() {
        var state = StreamingTranscriptState()
        state.apply([segment("One.", 0, 10_000), segment("Two.", 10_000, 30_000)], decodedFrom: 0, through: 32_000, isFinal: false)
        state.confirmPending(through: 40_000)
        #expect(state.confirmed == ["One.", "Two."])
        #expect(state.text == "One. Two.")
    }

    @Test func blankSegmentsAreDropped() {
        var state = StreamingTranscriptState()
        state.apply([segment("  ", 0, 5_000), segment("Hi.", 5_000, 9_000)], decodedFrom: 0, through: 10_000, isFinal: true)
        #expect(state.text == "Hi.")
    }
}

@MainActor
struct LiveTranscriptionControllerTests {
    /// 2s of speech, then further speech or silence, as the tests need.
    private let speech = [Float](repeating: 0.3, count: 32_000)

    /// Scripted by how much audio each decode is handed, so every ordering of
    /// the decode loop and `finish` reaches the same transcript:
    /// - the first 2s decode as "A." (confirmed) and "B." (at the edge, pending);
    /// - from A's end with 1s more speech: "B." (confirmed) and "C." (pending);
    /// - from B's end: "C.";
    /// - all 3s at once (nothing confirmed yet): all three.
    private func scriptedTranscriber(failFirst: Int = 0) -> FakeSegmentTranscriber {
        FakeSegmentTranscriber(failuresBeforeSuccess: failFirst) { samples in
            switch samples.count {
            case 32_000: [.init(text: " A.", startSample: 0, endSample: 12_000), .init(text: " B.", startSample: 12_000, endSample: 30_000)]
            case 36_000: [.init(text: " B.", startSample: 0, endSample: 18_000), .init(text: " C.", startSample: 18_000, endSample: 34_000)]
            case 18_000: [.init(text: " C.", startSample: 0, endSample: 16_000)]
            case 48_000: [
                .init(text: " A.", startSample: 0, endSample: 12_000),
                .init(text: " B.", startSample: 12_000, endSample: 30_000),
                .init(text: " C.", startSample: 30_000, endSample: 46_000),
            ]
            default: []
            }
        }
    }

    private func makeController(
        source: FakeLiveAudioSource,
        transcriber: FakeSegmentTranscriber?
    ) -> LiveTranscriptionController {
        LiveTranscriptionController(
            source: source,
            engineProvider: {
                guard let transcriber else { throw LiveTestFailure() }
                return transcriber
            },
            pollInterval: 0.005,
            minimumNewSamples: 1_000,
            minimumSampleCount: 1_000
        )
    }

    @Test func streamsPartialsAsTheRecordingArrives() async throws {
        let source = FakeLiveAudioSource()
        let transcriber = scriptedTranscriber()
        let controller = makeController(source: source, transcriber: transcriber)
        let partials = Collector<String>()

        controller.start { partials.append($0) }
        #expect(source.consumer != nil, "Start must subscribe to the live sample feed")
        source.push(samples: speech)
        try await waitUntil("the first partial arrives") { !partials.values.isEmpty }

        #expect(partials.values.first == "A. B.", "A partial is the confirmed text plus the unconfirmed tail")
        controller.stop()
    }

    @Test func eachDecodeStartsAtTheLastConfirmedSegment() async throws {
        let source = FakeLiveAudioSource()
        let transcriber = scriptedTranscriber()
        let controller = makeController(source: source, transcriber: transcriber)
        let partials = Collector<String>()

        controller.start { partials.append($0) }
        source.push(samples: speech)
        try await waitUntil("the first decode lands") { partials.values.count == 1 }
        source.push(samples: [Float](repeating: 0.3, count: 16_000))
        try await waitUntil("the second decode lands") { partials.values.count == 2 }

        #expect(transcriber.receivedCounts.prefix(2) == [32_000, 36_000], "Confirmed audio is never decoded twice")
        #expect(partials.values.last == "A. B. C.")
        controller.stop()
    }

    @Test func finishingAfterAPauseReusesTheLastDecode() async throws {
        let source = FakeLiveAudioSource()
        let transcriber = scriptedTranscriber()
        let controller = makeController(source: source, transcriber: transcriber)
        let updates = Collector<StreamingTranscriptUpdate>()

        controller.start(onPartial: { _ in }, onUpdate: { updates.append($0) })
        source.push(samples: speech)
        try await waitUntil("the first decode lands") { !updates.values.isEmpty }
        source.push(samples: [Float](repeating: 0, count: 16_000))
        try await waitUntil("the pause is reported") { updates.values.contains(where: \.endsInSilence) }

        let pause = try #require(updates.values.last)
        #expect(pause.text == "A. B.", "A pause reports exactly what stopping now would produce")
        let result = await controller.finish()

        #expect(result?.text == "A. B.")
        #expect(transcriber.receivedCounts == [32_000], "Stopping after a pause must not decode anything more")
        controller.stop()
    }

    @Test func finishingMidSpeechDecodesOnlyTheTail() async throws {
        let source = FakeLiveAudioSource()
        let transcriber = scriptedTranscriber()
        let controller = makeController(source: source, transcriber: transcriber)
        let partials = Collector<String>()

        controller.start { partials.append($0) }
        source.push(samples: speech)
        try await waitUntil("the first decode lands") { !partials.values.isEmpty }
        source.push(samples: [Float](repeating: 0.3, count: 16_000))
        let result = await controller.finish()

        #expect(result?.text == "A. B. C.")
        #expect(
            transcriber.receivedCounts.allSatisfy { $0 < 48_000 },
            "Stop must never re-decode the whole recording: \(transcriber.receivedCounts)"
        )
        controller.stop()
    }

    @Test func finishWithoutAnEngineFallsBackToTheFile() async throws {
        let source = FakeLiveAudioSource()
        let controller = makeController(source: source, transcriber: nil)

        controller.start { _ in }
        source.push(samples: speech)
        #expect(await controller.finish() == nil, "No engine means nothing trustworthy; the caller decodes the WAV")
    }

    @Test func aFailedTailDecodeFallsBackToTheFile() async throws {
        let source = FakeLiveAudioSource()
        let transcriber = FakeSegmentTranscriber { _ in throw LiveTestFailure() }
        let controller = makeController(source: source, transcriber: transcriber)

        controller.start { _ in }
        source.push(samples: speech)
        #expect(await controller.finish() == nil)
    }

    @Test func finishingBeforeStartingReturnsNothing() async {
        let controller = makeController(source: FakeLiveAudioSource(), transcriber: scriptedTranscriber())
        #expect(await controller.finish() == nil)
    }

    @Test func decodeFailuresWhileRecordingAreRetriedWithMoreAudio() async throws {
        let source = FakeLiveAudioSource()
        let transcriber = scriptedTranscriber(failFirst: 1)
        let controller = makeController(source: source, transcriber: transcriber)
        let partials = Collector<String>()

        controller.start { partials.append($0) }
        source.push(samples: speech)
        try await waitUntil("the failed decode is attempted") { transcriber.callCount == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(transcriber.callCount == 1, "A failure is not retried until new audio arrives")

        source.push(samples: [Float](repeating: 0.3, count: 16_000))
        try await waitUntil("a later decode succeeds") { !partials.values.isEmpty }
        #expect(partials.values.first == "A. B. C.", "Nothing was confirmed by the failure, so the retry covers everything")
        controller.stop()
    }

    @Test func doesNotDecodeWhenNoNewAudioArrived() async throws {
        let source = FakeLiveAudioSource()
        let transcriber = scriptedTranscriber()
        let controller = makeController(source: source, transcriber: transcriber)
        let partials = Collector<String>()

        controller.start { partials.append($0) }
        source.push(samples: speech)
        try await waitUntil("the single partial arrives") { partials.values.count == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(transcriber.callCount == 1, "Controller must not re-decode unchanged audio")
        controller.stop()
    }

    /// Regression (Codex review): a finish that resumes after the user
    /// cancelled and started again cleared the newer session's task, so the
    /// newer recording lost streaming and fell back to the file.
    @Test func aStaleFinishLeavesTheNewerSessionAlone() async throws {
        let source = FakeLiveAudioSource()
        let transcriber = FakeSegmentTranscriber { samples in
            Thread.sleep(forTimeInterval: 0.15)
            return [.init(text: " A.", startSample: 0, endSample: samples.count / 2)]
        }
        let controller = makeController(source: source, transcriber: transcriber)

        controller.start { _ in }
        source.push(samples: speech)
        try await waitUntil("a decode is in flight") { transcriber.callCount == 1 }
        async let stale = controller.finish()
        try await Task.sleep(nanoseconds: 10_000_000)
        controller.start { _ in }  // cancelled, recording again
        #expect(await stale == nil)

        source.push(samples: speech)
        #expect(await controller.finish()?.text == "A.", "The newer session must still stream")
    }

    @Test func stopUnsubscribesAndStopsEmitting() async throws {
        let source = FakeLiveAudioSource()
        let controller = makeController(source: source, transcriber: scriptedTranscriber())
        let partials = Collector<String>()

        controller.start { partials.append($0) }
        controller.stop()

        #expect(source.consumer == nil, "Stop must clear the live sample consumer")
        source.push(samples: speech)
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(partials.values.isEmpty, "No partials may be emitted after stop")
    }
}

// MARK: - Helpers

private struct LiveTestFailure: Error {}

@MainActor
private func waitUntil(
    _ what: Comment,
    timeout: TimeInterval = 3,
    condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            Issue.record("Timed out waiting until \(what)")
            return
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// MainActor-confined list of received values.
@MainActor
private final class Collector<Value> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
}

final class FakeLiveAudioSource: LiveAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _consumer: (@Sendable ([Float]) -> Void)?
    let broadcaster = InputLevelBroadcaster()

    var consumer: (@Sendable ([Float]) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return _consumer
    }

    func setLiveSampleConsumer(_ consumer: (@Sendable ([Float]) -> Void)?) {
        lock.lock()
        _consumer = consumer
        lock.unlock()
    }

    func inputLevels() -> AsyncStream<Float> {
        broadcaster.stream()
    }

    func push(samples: [Float]) {
        consumer?(samples)
    }
}

/// Answers each decode from a script keyed on the audio it is handed, and
/// records how much audio that was.
final class FakeSegmentTranscriber: LiveSampleTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private let respond: @Sendable ([Float]) throws -> [TimedSegment]
    private var remainingFailures: Int
    private var _receivedCounts: [Int] = []

    init(failuresBeforeSuccess: Int = 0, respond: @escaping @Sendable ([Float]) throws -> [TimedSegment]) {
        self.remainingFailures = failuresBeforeSuccess
        self.respond = respond
    }

    var receivedCounts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return _receivedCounts
    }

    var callCount: Int { receivedCounts.count }

    func transcribeSegments(
        _ samples: [Float],
        languageHint: String?,
        shouldContinue: @escaping @Sendable () -> Bool
    ) async throws -> SegmentedTranscript {
        let shouldFail: Bool = lock.withLock {
            _receivedCounts.append(samples.count)
            guard remainingFailures > 0 else { return false }
            remainingFailures -= 1
            return true
        }
        if shouldFail { throw LiveTestFailure() }
        return SegmentedTranscript(segments: try respond(samples), language: "en")
    }
}
