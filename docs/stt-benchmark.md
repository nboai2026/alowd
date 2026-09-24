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

## Latency Bench (`AlowdBench`)

`AlowdBench` measures the real WhisperKit and Ollama stages against the model and settings in `~/Alowd/config/settings.json`. Build it in release mode; debug builds are several times slower and say nothing about the app:

```bash
swift build -c release --product AlowdBench
```

Where the Whisper decode spends its time (encoder vs decoder, tokens/s), plus word error rate when a same-named `.txt` reference sits next to the `.wav`:

```bash
.build/release/AlowdBench samples/clip.wav
ALOWD_BENCH_MODEL=openai_whisper-small .build/release/AlowdBench samples/clip.wav
ALOWD_BENCH_ENCODER=gpu ALOWD_BENCH_DECODER=gpu .build/release/AlowdBench samples/clip.wav
```

Stop-to-text latency, the number the 2 s target is about. Each file is replayed in real time through streaming transcription and the incremental rewrite, then stopped on the last word and 0.7 s after it, and compared with the old path (decode the whole file, then rewrite the whole text). `ALOWD_BENCH_TRACE=1` logs every decode and every chunk rewrite relative to the stop press:

```bash
ALOWD_BENCH_E2E=1 ALOWD_BENCH_TRACE=1 .build/release/AlowdBench samples/clip.wav
```

Realistic test audio without recording anything: synthesize a past transcript, which keeps real dictation lengths and vocabulary. Keep it out of the repo, since it is your dictation:

```bash
say -r 165 -o /tmp/clip.wav --data-format=LEI16@16000 -f /tmp/clip.txt
```

Synthetic speech is cleaner than a microphone, so the WER it reports is a floor. Use it to compare models with each other, not as an absolute accuracy figure. Timings are sensitive to whatever else is using the GPU and Neural Engine, such as a browser on a video call, so compare medians of several runs.
