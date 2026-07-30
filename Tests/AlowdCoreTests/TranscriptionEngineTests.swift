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
