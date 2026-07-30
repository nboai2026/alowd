# STT Benchmark Notes

## Official WhisperKit Source

- Repository URL: `https://github.com/argmaxinc/argmax-oss-swift`
- Product: `.product(name: "WhisperKit", package: "argmax-oss-swift")` (see `Package.swift` for the current version requirement)
- Official prerequisites in README: macOS 14.0 or later, Xcode 16.0 or later.
- Upstream package platforms include macOS 13+, but Alowd targets macOS 14+ to match the README prerequisite.
- Recommended model for Apple Silicon laptop: `large-v3-v20240930_626MB` for accuracy; `tiny` for fastest debugging.
- Model path for Alowd: `~/Alowd/models/whisperkit/`.
- Current file API: `try await WhisperKit(...).transcribe(audioPath: audioFile.path)`.

## Benchmark Flow

Run:

```bash
Scripts/benchmark-stt.sh samples
```

The current script verifies the STT protocol boundary and deterministic stub. Real audio benchmark samples should be added under `samples/` only if you explicitly opt in to keeping those samples locally (the directory is gitignored).
