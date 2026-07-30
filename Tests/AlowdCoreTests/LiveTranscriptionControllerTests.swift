import Foundation
import Testing
@testable import AlowdCore

@MainActor
struct LiveTranscriptionControllerTests {
    @Test func forwardsThrottledPartialsFromLiveSamples() async throws {
        let source = FakeLiveAudioSource()
        let transcriber = FakeSampleTranscriber(texts: ["hello", "hello world"])
        let controller = LiveTranscriptionController(
            source: source,
            engineProvider: { transcriber },
            interval: 0.01,
            minimumSampleCount: 100
        )
        let partials = PartialCollector()

        controller.start { partials.append($0) }
        #expect(source.consumer != nil, "Start must subscribe to the live sample feed")

        source.push(samples: [Float](repeating: 0.1, count: 200))
        try await waitUntil("first partial arrives") { partials.values.count >= 1 }
        source.push(samples: [Float](repeating: 0.1, count: 200))
        try await waitUntil("second partial arrives") { partials.values.count >= 2 }

        #expect(partials.values.prefix(2) == ["hello", "hello world"], "Partials must be forwarded in order")
        controller.stop()
    }

    @Test func doesNotDecodeWhenNoNewAudioArrived() async throws {
        let source = FakeLiveAudioSource()
        let transcriber = FakeSampleTranscriber(texts: ["only once"])
        let controller = LiveTranscriptionController(
            source: source,
            engineProvider: { transcriber },
            interval: 0.01,
            minimumSampleCount: 100
        )
        let partials = PartialCollector()

        controller.start { partials.append($0) }
        source.push(samples: [Float](repeating: 0.1, count: 200))
        try await waitUntil("the single partial arrives") { partials.values.count == 1 }

        // No new samples: several throttle ticks later there is still exactly
        // one decode and one partial.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(transcriber.callCount == 1, "Controller must not re-decode unchanged audio")
        #expect(partials.values == ["only once"], "No new partial without new audio")
        controller.stop()
    }

    @Test func engineProviderFailureIsSilent() async throws {
        let source = FakeLiveAudioSource()
        let controller = LiveTranscriptionController(
            source: source,
            engineProvider: { throw LiveTestFailure() },
            interval: 0.01,
            minimumSampleCount: 100
        )
        let partials = PartialCollector()

        controller.start { partials.append($0) }
        source.push(samples: [Float](repeating: 0.1, count: 200))
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(partials.values.isEmpty, "A failed engine load must silently produce no partials")
        controller.stop()
    }

    @Test func decodeFailuresAreSkippedSilently() async throws {
        let source = FakeLiveAudioSource()
        let transcriber = FakeSampleTranscriber(texts: ["recovered"], failuresBeforeSuccess: 2)
        let controller = LiveTranscriptionController(
            source: source,
            engineProvider: { transcriber },
            interval: 0.01,
            minimumSampleCount: 100
        )
        let partials = PartialCollector()

        controller.start { partials.append($0) }
        for _ in 0..<3 {
            source.push(samples: [Float](repeating: 0.1, count: 200))
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try await waitUntil("partial arrives after decode failures") { !partials.values.isEmpty }

        #expect(partials.values.first == "recovered", "Decode failures must be skipped, not surfaced")
        controller.stop()
    }

    @Test func stopUnsubscribesAndStopsEmitting() async throws {
        let source = FakeLiveAudioSource()
        let transcriber = FakeSampleTranscriber(texts: ["late"])
        let controller = LiveTranscriptionController(
            source: source,
            engineProvider: { transcriber },
            interval: 0.01,
            minimumSampleCount: 100
        )
        let partials = PartialCollector()

        controller.start { partials.append($0) }
        controller.stop()

        #expect(source.consumer == nil, "Stop must clear the live sample consumer")
        source.push(samples: [Float](repeating: 0.1, count: 200))
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(partials.values.isEmpty, "No partials may be emitted after stop")
    }

    @Test func blankTranscriptsAreNotForwarded() async throws {
        let source = FakeLiveAudioSource()
        let transcriber = FakeSampleTranscriber(texts: ["   ", "real text"])
        let controller = LiveTranscriptionController(
            source: source,
            engineProvider: { transcriber },
            interval: 0.01,
            minimumSampleCount: 100
        )
        let partials = PartialCollector()

        controller.start { partials.append($0) }
        source.push(samples: [Float](repeating: 0.1, count: 200))
        try await Task.sleep(nanoseconds: 50_000_000)
        source.push(samples: [Float](repeating: 0.1, count: 200))
        try await waitUntil("non-blank partial arrives") { !partials.values.isEmpty }

        #expect(partials.values == ["real text"], "Whitespace-only partials must be dropped")
        controller.stop()
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

/// MainActor-confined list of received partials.
@MainActor
private final class PartialCollector {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
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

final class FakeSampleTranscriber: LiveSampleTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private let texts: [String]
    private var remainingFailures: Int
    private var successCount = 0
    private var _callCount = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    init(texts: [String], failuresBeforeSuccess: Int = 0) {
        self.texts = texts
        self.remainingFailures = failuresBeforeSuccess
    }

    func transcribeLiveSamples(_ samples: [Float]) async throws -> String {
        try nextResult()
    }

    private func nextResult() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        _callCount += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw LiveTestFailure()
        }
        let index = min(successCount, texts.count - 1)
        successCount += 1
        return texts[index]
    }
}
