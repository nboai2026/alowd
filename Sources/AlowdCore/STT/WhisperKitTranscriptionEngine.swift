import Foundation
@preconcurrency
import WhisperKit

public final class WhisperKitTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    private let whisperKit: WhisperKit
    private let language: String?
    private let translateToEnglish: Bool
    /// The live-partials path and the final decode share this one WhisperKit
    /// instance, and overlapping decodes corrupt its state — see DecodeGate.
    private let gate = DecodeGate()
    /// Last language a final decode confidently detected, reused by live
    /// partials. Guarded because the partial path reads it off the recording
    /// task while a final decode writes it.
    private let resolvedLanguageLock = NSLock()
    private var _lastResolvedLanguage: String?

    var lastResolvedLanguage: String? {
        get { resolvedLanguageLock.withLock { _lastResolvedLanguage } }
        set { resolvedLanguageLock.withLock { _lastResolvedLanguage = newValue } }
    }

    public init(
        modelPath: URL,
        modelRoot: URL,
        language: String? = nil,
        translateToEnglish: Bool = false
    ) async throws {
        self.language = language
        self.translateToEnglish = translateToEnglish
        self.whisperKit = try await WhisperKit(
            modelFolder: modelPath.path,
            tokenizerFolder: modelRoot,
            verbose: false,
            load: true,
            download: false
        )
    }

    /// Minimum log-probability for an auto-detected language to be trusted.
    /// Detection from a clean decoder scores about -0.007 or better; the
    /// degenerate cases sit near -1.5, so anything below this is a guess.
    static let minimumLanguageLogProb: Float = -0.5

    struct DetectedLanguage: Equatable {
        var code: String
        var logProb: Float
    }

    /// Decides which language token to decode with, and whether that choice is
    /// solid enough to tell the rest of the pipeline about.
    ///
    /// - Parameter lastResolved: the last language this engine detected
    ///   confidently, used only when detection produced nothing at all.
    /// - Returns: `decode` is the language token to hand Whisper — nil means
    ///   "no better idea than WhisperKit's own detection". `trusted` gates what
    ///   is reported upward: an untrusted guess is still the best token to
    ///   decode with, but naming it in the rewrite prompt would pin the local
    ///   model to a language the transcript may not be in.
    static func resolveLanguage(
        configured: String?,
        detected: DetectedLanguage?,
        lastResolved: String? = nil
    ) -> (decode: String?, trusted: Bool) {
        if let configured { return (configured, true) }
        guard let detected else { return (lastResolved, false) }
        return (detected.code, detected.logProb >= minimumLanguageLogProb)
    }

    public func transcribe(audioFile: URL) async throws -> TranscriptResult {
        let whisperKit = self.whisperKit
        let configured = self.language
        let decoded = try await gate.run { [self] in
            // Detect in a pass of our own rather than letting `transcribe` do it.
            // WhisperKit prefills the decoder KV cache for `<|en|>` before it
            // detects (options.language is nil, so TextDecoder falls back to
            // Constants.defaultLanguageCode), then runs detection against that
            // polluted cache. The language logits collapse — measured -0.001 from
            // a fresh decoder versus -1.9 through that path — and it answers "en",
            // whereupon Whisper translates the French instead of transcribing it.
            var detected: DetectedLanguage?
            if configured == nil,
               let result = try? await whisperKit.detectLanguage(audioPath: audioFile.path) {
                detected = DetectedLanguage(
                    code: result.language,
                    logProb: result.langProbs[result.language] ?? -.infinity
                )
            }
            let (resolved, trusted) = Self.resolveLanguage(
                configured: configured,
                detected: detected,
                // When our detection throws outright, the only remaining option
                // is WhisperKit's internal one — the broken path this method
                // exists to avoid. A language this session already detected
                // confidently beats it: dictation is overwhelmingly the same
                // language twice in a row, and the alternative decodes as
                // English and translates.
                lastResolved: lastResolvedLanguage
            )
            if trusted, configured == nil { lastResolvedLanguage = resolved }
            let results = try await whisperKit.transcribe(
                audioPath: audioFile.path,
                // Only fall back to WhisperKit's own detection if ours failed
                // outright; passing nil here would silently decode as English.
                decodeOptions: decodingOptions(language: resolved, detectLanguage: resolved == nil)
            )
            return (
                text: results.map(\.text).joined(separator: " "),
                // Report nothing rather than a guess. `transcribe` cannot tell
                // "detected English" from "detection failed" — both come back
                // as "en" — and a wrong language here pins the rewrite prompt to
                // the wrong language, which turns a bad transcript into a
                // translated one.
                language: trusted ? resolved : nil
            )
        }
        return TranscriptResult(text: decoded.text, confidence: 1.0, language: decoded.language)
    }

    private func decodingOptions(language: String?, detectLanguage: Bool) -> DecodingOptions {
        DecodingOptions(
            task: translateToEnglish ? .translate : .transcribe,
            language: language,
            detectLanguage: detectLanguage
        )
    }
}

extension WhisperKitTranscriptionEngine: LiveSampleTranscribing {
    /// Live partial decode path: same engine, same language/translate options,
    /// fed raw 16kHz mono samples accumulated during recording.
    public func transcribeLiveSamples(_ samples: [Float]) async throws -> String {
        let whisperKit = self.whisperKit
        // Reuse the language the last final decode resolved rather than paying
        // for a detection pass per partial — and rather than letting WhisperKit
        // detect internally, which is the path that returns "en" for French.
        // Before the first final decode there is nothing to reuse, so partials
        // fall back to internal detection and may flash a wrong language.
        //
        // Deliberate trade-off: switch language mid-session and partials keep
        // showing the previous one until the next final decode resolves it.
        // That is worth it — carrying over a language detected at ~99.9%
        // confidence is wrong only when the user switches, whereas the internal
        // path was wrong on every French recording measured. The batch result
        // is what actually gets inserted either way.
        let options = decodingOptions(
            language: language ?? lastResolvedLanguage,
            detectLanguage: language == nil && lastResolvedLanguage == nil
        )
        // Skipped rather than queued when the final decode holds the model:
        // a partial that waited its turn is stale, and the batch result is
        // what actually gets inserted.
        let text = try await gate.runIfFree {
            let results: [TranscriptionResult] = try await whisperKit.transcribe(
                audioArray: samples,
                decodeOptions: options
            )
            return results.map(\.text).joined(separator: " ")
        }
        return text ?? ""
    }
}
