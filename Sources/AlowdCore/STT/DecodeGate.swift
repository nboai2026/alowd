import Foundation

/// Serializes access to a single WhisperKit instance.
///
/// One `WhisperKit` owns mutable decoder state (KV/prefill caches). Two
/// overlapping `transcribe` calls interleave on that state and produce
/// corrupted output — most visibly a wrong detected language, so French audio
/// comes back as German or English. Overlap is easy to hit: stopping a
/// dictation cancels the live-partials task, but a decode already awaiting
/// inside WhisperKit keeps running while the final decode starts.
///
/// Batch decodes wait their turn (`run`) because they are the source of truth.
/// Live partial decodes skip instead of queueing (`runIfFree`): a partial that
/// waited is stale by the time it lands.
public actor DecodeGate {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Runs `body` once the model is free, waiting if necessary.
    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        while isBusy {
            await withCheckedContinuation { waiters.append($0) }
        }
        isBusy = true
        defer { release() }
        return try await body()
    }

    /// Runs `body` only if the model is idle right now; returns nil otherwise.
    public func runIfFree<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { release() }
        return try await body()
    }

    private func release() {
        isBusy = false
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
}
