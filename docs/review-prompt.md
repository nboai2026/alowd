# External review prompt — Alowd

Paste everything below the line into Fable / Codex / any reviewing model, with the repo available.

---

You are reviewing **Alowd**, a macOS menu-bar dictation app about to be published as a public open-source repository. Assume it will be read by security-minded strangers, installed by non-technical friends, and criticised on Hacker News. Your job is to find what would embarrass or endanger the author, then what would make people actually use and star it — in that order.

## What it is

Free, local-first dictation for macOS: press a global hotkey, speak, and the transcript is inserted into whatever app has focus. Positioned as a 100%-on-device alternative to Wispr Flow (cloud-only, $15/mo) and to paid local apps (superwhisper, VoiceInk, MacWhisper).

- **Stack**: Swift 6, SwiftPM, macOS 14+, SwiftUI. Sole dependency: [WhisperKit](https://github.com/argmaxinc/WhisperKit) (MIT) for on-device Core ML speech-to-text.
- **Layout**: `Sources/AlowdCore` (all logic, protocol seams, fakes in tests) and `Sources/AlowdApp` (SwiftUI menu bar, windows, composition root). `Tests/AlowdCoreTests` — 136 tests, Swift Testing, `swift test` green.
- **Build/verify**: `swift build`, `swift test`, `Scripts/package-app.sh` (builds `dist/Alowd.app`, ad-hoc signed, not notarized).
- **Docs worth reading first**: `README.md`, `docs/ROADMAP.md`, `docs/competitive-analysis.md`.

## How a dictation flows

1. `HotkeyController` — Carbon `RegisterEventHotKey` (deliberately **not** an event tap, so no Input Monitoring permission and no keylogging capability). Toggle or push-to-talk; Esc cancels while recording.
2. `StreamingAudioRecorder` — one `AVAudioEngine` input tap writes a 16 kHz mono WAV **and** feeds live samples/RMS to the overlay.
3. `LiveTranscriptionController` — throttled partial decodes of a trailing 10s window, display-only, best-effort.
4. `DictationSessionRunner` — `@MainActor` state machine (idle/recording/transcribing), caches the pipeline, moves retained audio, writes history **before** insertion.
5. `WhisperKitTranscriptionEngine` — batch transcription with explicit `DecodingOptions` (language / translate).
6. Post-processing — `RuleBasedPostProcessor` (fillers, punctuation, dictionary rules, snippets) and optional `OllamaPostProcessor` (localhost-only LLM rewrite, falls back to rules on any failure).
7. `ClipboardTextInserter` — writes the pasteboard, synthesizes Cmd+V via `CGEvent`, restores the previous clipboard ~0.5s later.
8. `AutoLearnController` — after a delay, re-reads the focused field via Accessibility, diffs it against what was inserted, and queues corrected words as dictionary suggestions for user review.

## Review priorities, highest first

### 1. Security and privacy — the bar is "no holes, no leaks"

Treat these as the known-dangerous surfaces and verify each properly, in code:

- **Accessibility reading (`AutoLearnController` + `LearningAnchor`)** — the app reads text out of *other applications*. It is supposed to refuse unless the frontmost app is the one it pasted into, secure input is off, the element is not a secure text field, and the field still contains its own insertion. **Try to defeat every one of those guards.** What about focus changes within the same app, web views/Electron where subrole is absent, multiple windows, a field containing our text plus a password typed after it? Is the delay a TOCTOU problem? Should this feature be opt-in rather than on by default?
- **Clipboard** (`TextInserter`) — transcript on the general pasteboard, synthetic Cmd+V, restore-after-delay. Consider clipboard managers, restore races, non-string pasteboard content, and whether failure paths can leave sensitive text on the clipboard indefinitely.
- **Synthetic events** — `CGEvent` posting. Any abuse potential, any way it lands in the wrong window, any interaction with secure input?
- **Data at rest** — transcripts (`~/Alowd/data/history.json`), learned vocabulary, snippets, optional retained audio, all plaintext in the home directory. Is that defensible and clearly documented? Does profile export leak more than a user expects? Retention/pruning correct?
- **Network** — assert that the *only* egress is the user-triggered Hugging Face model download, plus Ollama strictly to `127.0.0.1`/`localhost`. Try to find any other call, any way the localhost guard can be bypassed (URL parsing tricks, redirects, DNS rebinding, IPv6, user-supplied base URL).
- **Prompt injection** — dictated text and dictionary entries are interpolated into an LLM prompt. What can a malicious dictation or imported CSV do?
- **Supply chain** — dependency pinning in `Package.resolved`, the ad-hoc signing story, what a user actually trusts when running `Scripts/package-app.sh`.
- **Repo hygiene** — scan tracked files *and git history* for secrets, personal paths, emails, or anything identifying. Report anything found; do not fix it silently.

### 2. Correctness and robustness

Concurrency (Swift 6 isolation, `@unchecked Sendable` claims, unstructured `Task` lifetimes, cancellation), audio lifecycle races, hotkey edge cases, error paths that swallow failures, retain cycles in the window view models and the overlay panel, and anything that could strand a hot microphone or lose a transcript. State the concrete input/state that triggers each bug.

### 3. Publication readiness

README as a conversion surface (does a stranger understand the value in ten seconds?), LICENSE and third-party attribution correctness, CI coverage, whether the trademark-sensitive comparisons to Wispr Flow are fair and safe, missing `CONTRIBUTING`/`SECURITY.md`/issue templates, and honest gaps between what the README claims and what the code does.

### 4. Test quality

136 tests pass — say whether they *mean* anything. Look for tests that assert on fakes rather than behaviour, untested system boundaries, and the highest-value missing tests.

## Rules for your output

- **Verify in the code before claiming.** Cite `file:line`. If you are inferring, say so explicitly.
- **Include a concrete failure scenario** for every issue: the inputs or sequence, and the resulting wrong behaviour. No "consider possibly hardening".
- **Rank by severity** (critical / high / medium / low), security and privacy first. An issue that leaks user data outranks any amount of style.
- **Say what is already good**, briefly, so the author does not "fix" load-bearing decisions.
- **Do not rewrite the codebase.** Propose the smallest change that closes each issue.
- Flag anything where you disagree with a deliberate decision (e.g. clipboard-based insertion, plaintext history, auto-learning on by default) and argue the alternative.

Start with the Accessibility reading path and the network egress claims. Those are the two places where being wrong actually hurts a user.
