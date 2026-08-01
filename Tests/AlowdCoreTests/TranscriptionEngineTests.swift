import Foundation
import Testing
@testable import AlowdCore

struct TranscriptionEngineTests {
    @Test func stubEngineReturnsConfiguredTranscript() async throws {
        let engine = StubTranscriptionEngine(text: "hello Nick", confidence: 0.9)
        let result = try await engine.transcribe(audioFile: URL(fileURLWithPath: "/tmp/fake.wav"))
        #expect(result.text == "hello Nick", "Stub engine must return configured text")
        #expect(result.confidence == 0.9, "Stub engine must return configured confidence")
    }
}

/// Regression: WhisperKit prefills its decoder KV cache for `<|en|>` before it
/// runs the language detection inside `transcribe`, so detection scores collapse
/// (about -1.9 versus -0.001 from a clean decoder) and it answers "en" — Whisper
/// then translates French speech instead of transcribing it. Measured on six
/// French clips: the internal path detected fr 0/6 (en, th, id), detecting up
/// front first gets 6/6. The clip with a high noise floor produced
/// "So we're gonna try now I speak in French, does it work? I don't know."
/// through the internal path, matching a real history entry.
struct LanguageResolutionTests {
    typealias Engine = WhisperKitTranscriptionEngine
    typealias Detected = Engine.DetectedLanguage

    @Test func configuredLanguageWinsAndIsTrusted() {
        let (decode, trusted) = Engine.resolveLanguage(
            configured: "fr",
            detected: Detected(code: "en", logProb: -0.001)
        )
        #expect(decode == "fr", "An explicit language must not be second-guessed")
        #expect(trusted)
    }

    @Test func confidentDetectionIsUsedAndReported() {
        let (decode, trusted) = Engine.resolveLanguage(
            configured: nil,
            detected: Detected(code: "fr", logProb: -0.0033)
        )
        #expect(decode == "fr")
        #expect(trusted, "A near-certain detection must be reported to the rewrite stage")
    }

    @Test func weakDetectionStillDecodesButIsNotReported() {
        // Decoding with a weak guess still beats the alternative: passing nil
        // makes WhisperKit prefill `<|en|>`, which translates French audio.
        let (decode, trusted) = Engine.resolveLanguage(
            configured: nil,
            detected: Detected(code: "is", logProb: -1.9124)
        )
        #expect(decode == "is")
        #expect(!trusted, "A coin-flip detection must not pin the rewrite prompt's language")
    }

    @Test func failedDetectionReportsNothing() {
        let (decode, trusted) = Engine.resolveLanguage(configured: nil, detected: nil)
        #expect(decode == nil, "Nil defers to WhisperKit's own detection rather than forcing a language")
        #expect(!trusted)
    }

    @Test func failedDetectionFallsBackToTheLastConfidentLanguage() {
        // Deferring to WhisperKit's internal detection is the broken path this
        // whole change avoids, so a language already established this session is
        // the better last resort.
        let (decode, trusted) = Engine.resolveLanguage(
            configured: nil,
            detected: nil,
            lastResolved: "fr"
        )
        #expect(decode == "fr", "A previously detected language beats falling back to the polluted path")
        #expect(!trusted, "A carried-over language is an assumption, not a detection")
    }

    @Test func liveDetectionOutranksTheCarriedOverLanguage() {
        let (decode, trusted) = Engine.resolveLanguage(
            configured: nil,
            detected: Detected(code: "de", logProb: -0.002),
            lastResolved: "fr"
        )
        #expect(decode == "de", "A fresh confident detection must win over the previous dictation's language")
        #expect(trusted)
    }

    @Test func thresholdSitsBetweenTheTwoObservedClusters() {
        #expect(Engine.minimumLanguageLogProb > -1.1, "Must reject the degenerate cluster near -1.1 and below")
        #expect(Engine.minimumLanguageLogProb < -0.007, "Must accept real detections, the worst measured at -0.007")
    }
}
