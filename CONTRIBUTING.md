# Contributing

Thanks for considering a contribution.

## Getting started

```bash
swift build
swift test          # 136 tests, should be green before and after your change
swift run AlowdApp  # or Scripts/package-app.sh for a real .app bundle
```

## Layout

- `Sources/AlowdCore` — all logic, behind protocol seams (`TranscriptionEngine`, `PostProcessor`, `TextInserter`, `TemporaryAudioRecorder`, …) with fakes in tests. Platform-free where possible.
- `Sources/AlowdApp` — SwiftUI menu bar, windows, and the composition root that wires everything together.
- `Tests/AlowdCoreTests` — Swift Testing. Prefer behaviour over implementation detail.

## Ground rules

- **Privacy is the product.** Anything that adds network access, widens what the app reads from other applications, or writes new user data to disk needs a clear justification in the pull request, and documentation in the README's Privacy section.
- Keep new logic in `AlowdCore` with tests; the app layer should stay thin.
- Match the surrounding style. Comments explain constraints, not narration.
- Run `swift test` before opening a PR. CI runs build + tests on macOS.

## Good first issues

Look for the `good first issue` label. The [roadmap](docs/ROADMAP.md) lists larger pieces that are not started yet.
