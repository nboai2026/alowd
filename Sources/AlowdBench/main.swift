import Foundation
import CoreML
@preconcurrency import WhisperKit
import AlowdCore

// Where the WhisperKit decode spends its time, on real files, against the
// model the app is configured with.
//
//   AlowdBench <wav>...
//   ALOWD_BENCH_MODEL=<folder name>   use another installed snapshot
//   ALOWD_BENCH_ENCODER=gpu|ane|all   encoder compute units (default ane)
//   ALOWD_BENCH_DECODER=gpu|ane|all   decoder compute units (default ane)
//   ALOWD_BENCH_OLLAMA_MODEL=<name>   rewrite model for the E2E run
//   ALOWD_BENCH_E2E=1                 replay each file in real time through
//                                     streaming + incremental rewrite and time
//                                     stop -> final text, against today's path
let env = ProcessInfo.processInfo.environment
let settings = try ProfileStore().loadSettings()
let modelRoot = AlowdPaths.whisperKitModelRoot(profileRoot: settings.profileDirectory)
//   ALOWD_BENCH_DOWNLOAD=<whisperkit name>  install a snapshot into Alowd's model root
if let name = env["ALOWD_BENCH_DOWNLOAD"] {
    let variant = WhisperKitModelVariant(id: name, displayName: name, whisperKitName: name)
    let installed = try await WhisperKitModelManager.install(variant: variant, in: modelRoot) { progress in
        if let progress, Int(progress * 100) % 10 == 0 { print("download \(Int(progress * 100))%") }
    }
    print("installed \(installed.path)")
    exit(0)
}
let folder: URL
if let name = env["ALOWD_BENCH_MODEL"] {
    folder = modelRoot.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(name)")
} else {
    let status = WhisperKitModelManager.status(in: modelRoot, variant: .named(settings.modelVariant))
    guard let installed = status.modelFolder else { fatalError(status.message) }
    folder = installed
}

func units(_ name: String?) -> MLComputeUnits {
    switch name {
    case "gpu": .cpuAndGPU
    case "all": .all
    default: .cpuAndNeuralEngine
    }
}
let compute = ModelComputeOptions(
    audioEncoderCompute: units(env["ALOWD_BENCH_ENCODER"]),
    textDecoderCompute: units(env["ALOWD_BENCH_DECODER"])
)

func time<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
    let start = Date()
    let value = try await body()
    return (value, Date().timeIntervalSince(start))
}
func f(_ x: Double) -> String { String(format: "%.2f", x) }

let (kit, loadSeconds) = try await time {
    try await WhisperKit(WhisperKitConfig(
        modelFolder: folder.path, tokenizerFolder: modelRoot, computeOptions: compute,
        verbose: false, load: true, download: false
    ))
}
print("model \(folder.lastPathComponent) enc=\(env["ALOWD_BENCH_ENCODER"] ?? "ane") dec=\(env["ALOWD_BENCH_DECODER"] ?? "ane") load \(f(loadSeconds))s")

let language = settings.language ?? "en"
func options(_ strategy: ChunkingStrategy? = nil) -> DecodingOptions {
    DecodingOptions(task: .transcribe, language: language, detectLanguage: false, chunkingStrategy: strategy)
}
// Warm the pipelines so the first measured decode is representative.
_ = try await kit.transcribe(audioArray: [Float](repeating: 0, count: 16_000), decodeOptions: options())

func breakdown(_ results: [TranscriptionResult]) -> String {
    guard let t = results.first?.timings else { return "" }
    return "enc \(f(t.encoding))s/\(Int(t.totalEncodingRuns)) runs, decode loop \(f(t.decodingLoop))s (predict \(f(t.decodingPredictions))s) \(Int(t.totalDecodingLoops)) tok, \(String(format: "%.0f", t.tokensPerSecond)) tok/s, fallbacks \(Int(t.totalDecodingFallbacks))"
}

if env["ALOWD_BENCH_E2E"] != nil {
    try await endToEnd(paths: Array(CommandLine.arguments.dropFirst()))
    exit(0)
}

for path in CommandLine.arguments.dropFirst() {
    let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
    print("\n\(URL(fileURLWithPath: path).lastPathComponent)  \(String(format: "%.1f", Double(samples.count) / 16_000))s audio")
    let (result, full) = try await time { try await kit.transcribe(audioArray: samples, decodeOptions: options()) }
    print("  full \(f(full))s  [\(breakdown(result))]")
    // Word error rate against a same-named .txt reference, when one exists.
    if let reference = try? String(contentsOfFile: (path as NSString).deletingPathExtension + ".txt", encoding: .utf8) {
        let hypothesis = result.map(\.text).joined(separator: " ")
        print("  WER \(String(format: "%.1f", wordErrorRate(reference: reference, hypothesis: hypothesis) * 100))%")
    }
    for tail in [2.0, 8.0] {
        let slice = Array(samples.suffix(Int(tail * 16_000)))
        let (r, t) = try await time { try await kit.transcribe(audioArray: slice, decodeOptions: options()) }
        print("  tail \(Int(tail))s \(f(t))s  [\(breakdown(r))]")
    }
}

func words(_ text: String) -> [String] {
    text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
        .filter { !$0.isEmpty }
}

func wordErrorRate(reference: String, hypothesis: String) -> Double {
    let r = words(reference), h = words(hypothesis)
    guard !r.isEmpty else { return 0 }
    var previous = Array(0...h.count)
    for i in 1...r.count {
        var current = [i] + Array(repeating: 0, count: h.count)
        for j in stride(from: 1, through: h.count, by: 1) {
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
        }
        previous = current
    }
    return Double(previous[h.count]) / Double(r.count)
}

// MARK: - End to end

/// Stands in for the microphone: hands samples to the streaming consumer.
final class ReplaySource: LiveAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var consumer: (@Sendable ([Float]) -> Void)?
    func setLiveSampleConsumer(_ consumer: (@Sendable ([Float]) -> Void)?) { lock.withLock { self.consumer = consumer } }
    func inputLevels() -> AsyncStream<Float> { AsyncStream { $0.finish() } }
    func push(_ samples: [Float]) { lock.withLock { consumer }?(samples) }
}

@MainActor
func endToEnd(paths: [String]) async throws {
    let rewriteModel = env["ALOWD_BENCH_OLLAMA_MODEL"] ?? settings.ollamaModel
    guard settings.enableOllamaRewrite else { fatalError("The end-to-end bench measures the Ollama rewrite; enable it first.") }
    let engine = try await WhisperKitTranscriptionEngine(
        modelPath: folder, modelRoot: modelRoot, language: settings.language, translateToEnglish: settings.translateToEnglish
    )
    let ollama = OllamaPostProcessor(
        config: OllamaConfig(baseURL: settings.ollamaBaseURL, model: rewriteModel),
        client: URLSessionOllamaHTTPClient(),
        fallback: RuleBasedPostProcessor()
    )
    let dictionary = (try? ProfileStore().loadDictionary()) ?? []
    let mode = settings.defaultMode
    // Warm both engines so neither pays a first-use cost inside a measurement.
    _ = try await engine.transcribeSegments([Float](repeating: 0, count: 16_000), languageHint: nil, shouldContinue: { true })
    _ = try await ollama.process(PostProcessingInput(rawText: "Warming up.", mode: mode, dictionary: dictionary, snippets: []))

    for path in paths {
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        let name = URL(fileURLWithPath: path).lastPathComponent
        print("\n\(name)  \(f(Double(samples.count) / 16_000))s audio  (mode \(mode.rawValue), \(URL(fileURLWithPath: folder.path).lastPathComponent), \(rewriteModel))")

        // Today: decode the whole file after stop, then rewrite the whole text.
        let baselineStart = Date()
        let batch = try await engine.transcribe(audioFile: URL(fileURLWithPath: path))
        let baselineDecoded = Date()
        _ = try await ollama.process(PostProcessingInput(rawText: batch.text, mode: mode, dictionary: dictionary, snippets: [], language: batch.language))
        let baselineDone = Date()
        print("  before: \(f(baselineDone.timeIntervalSince(baselineStart)))s after stop  (decode \(f(baselineDecoded.timeIntervalSince(baselineStart)))s + rewrite \(f(baselineDone.timeIntervalSince(baselineDecoded)))s)")

        for pause in [0.0, 0.7] {
            let source = ReplaySource()
            let tracedEngine = TracingEngine(inner: engine, trace: env["ALOWD_BENCH_TRACE"] != nil)
            let controller = LiveTranscriptionController(source: source, engineProvider: { tracedEngine })
            let traced = TracingProcessor(inner: ollama)
            let rewriter = IncrementalRewriter(processor: traced, mode: mode, dictionary: dictionary, snippets: [], language: settings.language)
            var latest: StreamingTranscriptUpdate?
            controller.start(onPartial: { _ in }, onUpdate: { update in
                latest = update
                let chunks = update.endsInSilence
                    ? RewriteChunker.chunks(update.text)
                    : RewriteChunker.closedChunks(update.confirmedText)
                Task { await rewriter.prefetch(chunks, speculative: update.endsInSilence) }
            })
            // Real time, in the 100 ms buffers a microphone delivers.
            let audio = samples + [Float](repeating: 0, count: Int(pause * 16_000))
            let clock = ContinuousClock()
            let began = clock.now
            var offset = 0
            while offset < audio.count {
                let end = min(audio.count, offset + 1_600)
                source.push(Array(audio[offset..<end]))
                offset = end
                try await clock.sleep(until: began + .milliseconds(offset / 16))
            }

            let stop = Date()
            traced.mark(stop)
            if let latest {
                let atStop = latest.endsInSilence ? RewriteChunker.chunks(latest.text) : RewriteChunker.closedChunks(latest.text)
                Task { await rewriter.prefetch(atStop, speculative: latest.endsInSilence) }
            }
            guard let streamed = await controller.finish() else {
                print("  after (pause \(pause)s): streaming returned nothing — would fall back")
                continue
            }
            let transcribed = Date()
            let final = try await rewriter.rewrite(streamed.text)
            let done = Date()
            controller.stop()
            print("  after  (stop \(pause == 0 ? "on the last word" : "\(pause)s after it")): \(f(done.timeIntervalSince(stop)))s after stop  (tail \(f(transcribed.timeIntervalSince(stop)))s + rewrite \(f(done.timeIntervalSince(transcribed)))s)  WER vs batch \(String(format: "%.1f", wordErrorRate(reference: batch.text, hypothesis: streamed.text) * 100))%")
            if env["ALOWD_BENCH_TRACE"] != nil { traced.report() }
            if pause > 0, env["ALOWD_BENCH_SHOW"] != nil { print("    \(final.prefix(300))") }
        }
    }
}

/// Logs when each chunk's rewrite ran, relative to the stop press.
final class TracingProcessor: PostProcessor, @unchecked Sendable {
    private let inner: PostProcessor
    private let lock = NSLock()
    private var events: [(chunk: String, start: Date, end: Date, cancelled: Bool)] = []
    private var stop: Date?
    init(inner: PostProcessor) { self.inner = inner }
    func mark(_ date: Date) { lock.withLock { stop = date } }
    func process(_ input: PostProcessingInput) async throws -> String {
        let start = Date()
        let out = try await inner.process(input)
        lock.withLock { events.append((input.rawText, start, Date(), Task.isCancelled)) }
        return out
    }
    func report() {
        lock.withLock {
            guard let stop else { return }
            for e in events {
                print(String(format: "    rewrite %+6.2fs → %+6.2fs  %3d ch%@  %@", e.start.timeIntervalSince(stop), e.end.timeIntervalSince(stop), e.chunk.count, e.cancelled ? " (cancelled)" : "", String(e.chunk.prefix(50))))
            }
        }
    }
}

/// Logs every streaming decode: how much audio, how long, what came back.
final class TracingEngine: LiveSampleTranscribing, @unchecked Sendable {
    private let inner: LiveSampleTranscribing
    private let trace: Bool
    private let began = Date()
    init(inner: LiveSampleTranscribing, trace: Bool) { self.inner = inner; self.trace = trace }
    func transcribeSegments(_ samples: [Float], languageHint: String?, shouldContinue: @escaping @Sendable () -> Bool) async throws -> SegmentedTranscript {
        let start = Date()
        do {
            let result = try await inner.transcribeSegments(samples, languageHint: languageHint, shouldContinue: shouldContinue)
            if trace {
                let segs = result.segments.map { String(format: "%.1f-%.1f", Double($0.startSample) / 16_000, Double($0.endSample) / 16_000) }.joined(separator: " ")
                print(String(format: "    decode @%5.1fs  %5.1fs audio in %4.2fs  → %d segs [%@]", start.timeIntervalSince(began), Double(samples.count) / 16_000, Date().timeIntervalSince(start), result.segments.count, segs))
            }
            return result
        } catch {
            if trace { print(String(format: "    decode @%5.1fs  %5.1fs audio ABANDONED after %4.2fs", start.timeIntervalSince(began), Double(samples.count) / 16_000, Date().timeIntervalSince(start))) }
            throw error
        }
    }
}
