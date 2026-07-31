import Foundation
import Testing
@testable import AlowdCore

/// Counts how many bodies are inside the gate at once, so a test can assert
/// that two decodes never overlap on the shared model.
private final class OverlapCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var maxConcurrent = 0

    func enter() {
        lock.lock()
        current += 1
        maxConcurrent = max(maxConcurrent, current)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        current -= 1
        lock.unlock()
    }
}

struct DecodeGateTests {
    @Test func concurrentRunsNeverOverlap() async throws {
        let gate = DecodeGate()
        let counter = OverlapCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? await gate.run {
                        counter.enter()
                        try await Task.sleep(for: .milliseconds(20))
                        counter.leave()
                    }
                }
            }
        }

        #expect(counter.maxConcurrent == 1, "Only one decode may touch the model at a time")
    }

    @Test func runIfFreeSkipsWhileBusy() async throws {
        let gate = DecodeGate()
        let blocker = Task {
            try await gate.run {
                try await Task.sleep(for: .milliseconds(200))
                return "batch"
            }
        }
        try await Task.sleep(for: .milliseconds(40))

        let skipped = try await gate.runIfFree { "live" }
        #expect(skipped == nil, "A live partial must skip rather than queue behind the final decode")
        _ = try await blocker.value
    }

    @Test func runIfFreeProceedsWhenIdle() async throws {
        let gate = DecodeGate()
        let result = try await gate.runIfFree { "live" }
        #expect(result == "live", "A live partial must run when the model is idle")
    }

    @Test func waitersResumeAfterAFailedRun() async throws {
        struct Boom: Error {}
        let gate = DecodeGate()
        async let failing: Void = {
            _ = try? await gate.run { throw Boom() }
        }()
        await failing

        let after = try await gate.run { "still usable" }
        #expect(after == "still usable", "A thrown decode must still release the gate")
    }
}
