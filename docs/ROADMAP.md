# Roadmap

Local, private, menu-bar dictation for macOS (WhisperKit STT, optional localhost Ollama rewrite, clipboard-based insertion). This roadmap follows a July 2026 internal audit and the original design spec.

## v1.1 (this release)

Reliability and hygiene release: fixed the recording start race, local tokenizer resolution, insertion failure handling, and hotkey auto-repeat/release handling; added a language/translation setting (French output now possible); wired up history recording; cached the WhisperKit engine between dictations (no more per-dictation model reload); converted the check suite into a real `swift test` target; and cleaned the project for open-sourcing (identity scrub, LICENSE, README, gitignore).

## v2

Prioritized feature list, informed by the competitive analysis ([docs/competitive-analysis.md](competitive-analysis.md)). Effort: **S** ≈ hours–1 day, **M** ≈ a few days, **L** ≈ a week or more.

### 1. History dashboard — M
A main window ("Hub") with past dictations grouped by day, search, copy/re-insert, delete-all, a retention setting, and a stats card (streak, average WPM, total words dictated) — modeled on Wispr Flow's Hub, one of its most-loved surfaces. Builds on the now-wired `HistoryStore`.
*Rationale:* top user request ("I set a prompt but it didn't paste — I don't know where it went"). Recording exists as of v1.1 but there is no way to view it; the dashboard is also the recovery path whenever insertion fails. Pure SwiftUI over existing data.

### 2. Dictionary manager UI + auto-learning loop — M/L
Two halves:
- **Manager window (M):** list/add/edit/delete `DictionaryTerm` entries (words *and* phrases), misspelling→correction replacement rules, CSV import/export (migration path *from* Wispr Flow/superwhisper), and a snippet editor for `SnippetExpander`.
- **Auto-learning (M):** replicate Wispr Flow's mechanism locally — after insertion, re-read the target text field via the Accessibility API, diff it against what was inserted, extract word-level corrections, filter out common words with a frequency list, and feed candidates to `DictionaryLearner`. Unlike Wispr, put candidates in a **review queue** ("Learned 'WhisperKit' — keep?") so the user stays in control. Per-app vocabulary is an open flank Wispr doesn't cover.
*Rationale:* second top user request ("the system needs to learn how I talk and auto-correct the words it usually misses"); auto-learning from corrections is Wispr Flow's crown jewel and **no local/open-source competitor has it** — this is Alowd's chance to own a differentiator, not just catch up.

### 3. Live dictation overlay — M/L
A small floating panel shown while dictating: recording indicator, input waveform, and a live partial transcript. Uses WhisperKit's `AudioStreamTranscriber` streaming API for partial results, falling back to the current batch pipeline when streaming is unavailable (e.g. unsupported model or first-run install).
*Rationale:* the signature Wispr Flow interaction ("Flow Bar") and the biggest visibility gap; also solves the "is it even listening?" trust problem. The pipeline is batch today, so this touches `AudioRecorder`, the engine, and `DictationSessionRunner` — the largest v2 item.

### 4. Model picker — S/M
Choose between `base`, `small`, and `large-v3-turbo`, with per-variant install status and download handled by `WhisperKitModelManager`.
*Rationale:* `base` is hard-coded today and is noticeably weaker for bilingual FR/EN use; the manager already handles install/verify, so this is mostly settings UI plus a variant parameter.

### 5. Push-to-talk hold mode, cancel hotkey, undo last insertion — M
Hold-to-dictate (start on key press, stop on release), a dedicated cancel shortcut, and an "undo last insertion" action.
*Rationale:* builds directly on the v1.1 key-release handling in `HotkeyController`; push-to-talk is the fastest interaction model for short dictations, and cancel/undo remove the current all-or-nothing feel.

### 6. Onboarding / permissions window — S/M
A first-run checklist driven by `PermissionStatus` (microphone, accessibility), with deep links into System Settings panes and a guided first-dictation test.
*Rationale:* TCC failures are the number-one setup trap for friends building from source; `PermissionStatus` is already implemented and tested, it just needs a UI.

### 7. Settings window — M
A proper settings UI: Ollama rewrite toggle, model name and URL with a connectivity check; audio retention; launch-at-login via `SMAppService`; profile export/import UI. Export exists (`ProfileExporter`); **import needs implementing**.
*Rationale:* everything is currently menu items or hand-edited JSON; a settings window is table stakes once other users exist, and import is required for the export feature to be useful at all.

### 8. Menu-bar state icon — S
Distinct icon states for idle / recording / transcribing.
*Rationale:* a hot microphone must never be invisible — this is a trust issue for a dictation tool, and it is a small change. If the overlay (item 1) slips, ship this first.

### 9. App-aware mode routing — M
Implement `ContextRouter` from the design spec: detect the frontmost app (bundle ID) and map it to a default dictation mode (e.g. casual in Messages, formal in Mail, no rewrite in terminals/IDEs), à la VoiceInk's "Power Mode".
*Rationale:* spec'd but never built; delivers ~80% of Wispr Flow's context-awareness value without reading screen content (no extra permissions, no privacy cost).

### 10. App bundle + notarized release artifacts — M
Real `.app` bundle with `Info.plist` (including `NSMicrophoneUsageDescription`), codesigning and notarization, and a GitHub Actions release workflow producing downloadable artifacts.
*Rationale:* a bare SPM executable gets per-binary TCC grants that break on every rebuild; a stable signed bundle is the prerequisite for anyone non-technical to use the app.

## v3 / ideas

- **Command Mode via Ollama** — select text anywhere, hold a hotkey, speak an instruction ("make this more formal", "turn into bullets") and have the local LLM rewrite it in place. Wispr Flow charges $15/mo for this; local Ollama does it free.
- **Streaming partial insertion** — type text into the target app as it is transcribed, instead of one paste at the end (depends on the live overlay's streaming pipeline).
- **Speaker-adaptive vocabulary** — bias decoding toward the user's dictionary and learned terms; possibly per-context vocabularies.
- **iOS / iPadOS companion?** — WhisperKit runs on iOS; explore a keyboard extension or share-sheet dictation. Big scope, uncertain value — evaluate after v2.
- **Multilingual output profiles** — per-language rewrite prompts and formatting rules (e.g. FR typography), quick language switching or auto language detection per dictation.
