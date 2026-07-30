# Competitive Analysis — Dictation Apps for macOS (July 2026)

Research comparing Alowd against Wispr Flow, superwhisper, VoiceInk, MacWhisper, Aqua Voice, Apple built-in dictation, and open-source tools (Handy, Talon).

## 1. Wispr Flow (primary reference)

**(a) Personal dictionary & auto-learning** — the crown jewel ([dictionary docs](https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary)):
- **Manual add**: Dictionary UI for words *and multi-word phrases* (60-char limit); right-click an underlined word in the scratchpad → "Add to Dictionary".
- **Auto-add from post-insertion edits**: Flow **monitors the text field where it pasted** and diffs it against what it inserted. If you retype/respell a word after insertion, the corrected spelling is auto-added. It **filters out common everyday words** so only distinctive/specialized terms get learned — this filtering keeps the dictionary noise-free. Toggleable.
- **Replacement rules**: toggle "Correct a misspelling" and specify the wrong spelling Flow keeps producing → automatic swap. One replacement rule per word.
- **Contacts sync** (iOS) populates the dictionary; **bulk CSV import** on desktop up to 1,000 entries including misspelling/correction pairs; sync across devices.
- Dictionary is **global**, not per-app (per-app adaptation happens via context awareness).

**(b) History/dashboard**: "Hub" window — transcript history **grouped by day** + stats card with **streak, average WPM, total words dictated** ([docs](https://docs.wisprflow.ai/articles/5096240724-navigating-the-wispr-flow-app-desktop-ios-and-android)).

**(c) Live feedback**: the **Flow Bar** — floating pill at screen bottom with recording state/waveform.

**(d) Context awareness** ([docs](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness)): reads locally: active app ID, on-screen text near cursor, email recipient names, Slack/Messages conversation history, file names in VS Code/Cursor, website identity in browsers. Used for proper-noun accuracy, per-app-category style, smart casing. Never reads password fields.

**(e) Formatting/tone/AI**: auto-edits (fillers, punctuation, lists), per-app tone; **Command Mode**: select text, hold hotkey, speak an instruction ("make this more formal") ([docs](https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode)). **Whisper Mode**: accurate transcription of near-silent speech.

**(f) Multilingual**: 100+ languages via a model ensemble; auto-detect with mid-stream switching ([docs](https://docs.wisprflow.ai/articles/3191899797-use-flow-with-multiple-languages)).

**(g) Pricing/posture**: **cloud-only** (all audio server-side — the key attack surface for a local-first competitor). Free ~2,000 words/week; Pro $15/mo or $144/yr.

## 2. superwhisper

- Custom vocabulary with CSV import + replacement rules; vocabulary/modes/models sync between Macs. No auto-learning from corrections.
- History list with recordings + transcripts; floating recording HUD with waveform.
- **Modes auto-activate per app**; each mode bundles STT model + AI prompt + hotkey; second AI pass via local Llama or BYOK GPT/Claude ([superwhisper.com](https://superwhisper.com/)).
- 100+ languages; translation is Pro. Local-first STT. Free tier: unlimited small local models; Pro $8.49/mo, $249.99 lifetime.

## 3. MacWhisper

- Primarily file transcription; dictation secondary. Global find-and-replace rules, vocabulary export; BYOK AI post-processing; fully local; free tier + ~€59 one-time. No auto-learning, no context awareness, minimal live UX.

## 4. VoiceInk (closest open-source competitor)

([GitHub](https://github.com/beingpax/VoiceInk), GPLv3, 3,700+ stars, whisper.cpp):
- Personal dictionary with custom words and smart text replacements — manual only, **no auto-learning** (real gap vs Wispr).
- Transcription history with audio retention controls; mini/notch recorder indicator.
- **Power Mode**: auto-applies configurations (mode, prompt, model) based on **active app or browser URL** (~10 smart modes).
- AI enhancement via local Ollama or BYOK. 100% offline STT; free if built from source, $25–49 one-time binaries.

## 5. Aqua Voice

- Cloud "fusion transcription" + client context engine reading the active screen; sub-500ms **streaming** dictation. Dictionary up to 800 terms (Pro). 49 languages. Cloud-only, $8/mo.

## 6. Apple built-in dictation (the free baseline)

- On-device, free, unlimited; macOS Tahoe (26) rebuilt on **SpeechAnalyzer/SpeechTranscriber** (Neural Engine, ~55% faster than Whisper offline). Auto-punctuation, keyboard+voice simultaneously. **No** custom dictionary UI, no AI rewrite/tone, no history, no per-app context. Note: `SpeechAnalyzer` is itself a candidate STT backend alongside WhisperKit.

## 7. Open-source tools worth stealing from

- **Handy** ([GitHub](https://github.com/cjpais/handy)): MIT, Rust, offline; push-to-talk; the best open-source **model picker** UX (Whisper variants, Parakeet, Moonshine, custom GGML).
- **Talon**: full voice computer control; steal the idea of a few **spoken formatting commands** ("new line", "cap that").

## Feature comparison matrix

| Feature | Wispr Flow | superwhisper | VoiceInk | MacWhisper | Apple (Tahoe) | Alowd today | Alowd v2 planned |
|---|---|---|---|---|---|---|---|
| Local/on-device STT | No (cloud only) | Yes | Yes | Yes | Yes | **Yes (WhisperKit)** | Yes |
| Personal dictionary (manual) | Yes (words+phrases) | Yes (CSV) | Yes | Replace rules only | No | Partial (rules) | **Yes (manager UI)** |
| **Auto-learn from post-insertion edits** | **Yes** (diff pasted text, filter common words) | No | No | No | No | No | **Yes (planned)** |
| Replacement/misspelling rules | Yes (1 per word) | Yes | Yes | Yes | No | Yes (rule-based) | Yes |
| CSV import/export | Yes (1,000) | Import | ? | Export | No | No | Easy add |
| History + stats dashboard | Yes (streak, WPM, words) | History list | Yes | Per-file | No | No | **Yes (planned)** |
| Live feedback UI | Flow Bar pill | Floating HUD | Mini recorder | Minimal | Inline popup | Minimal | **Live overlay (planned)** |
| Streaming/live transcript | Partial | No (batch) | No (batch) | No | Yes | No (batch) | Overlay planned |
| Per-app context awareness | Yes (screen text, recipients) | Per-app modes | Power Mode (app/URL) | No | No | No | Candidate |
| Modes / tone presets | Auto per app category | Custom modes | Smart modes | No | No | 3 modes | Keep + extend |
| AI rewrite / command mode | Yes (Command Mode) | Via modes | Via assistant | BYOK | No | Ollama rewrite | Extend |
| Push-to-talk + toggle | Both | Both | Both | — | Toggle | Toggle only | **PTT planned** |
| Model picker | N/A (cloud) | Yes | Yes | Yes | No | No | **Yes (planned)** |
| Multilingual / auto-detect | 100+, auto-switch | 100+ | Whisper langs | Whisper langs | Many | Whisper langs (config lands in v1.1) | — |
| Price | $15/mo | $8.49/mo / $249 lifetime | $25–49 / free build | €59 once | Free | **Free OSS** | Free OSS |

## Differentiation opportunities for Alowd (free, open-source, local)

**Cheap wins that match/beat Wispr Flow:**
1. **Wispr-style auto-learning dictionary — highest-value replication.** Mechanism: after clipboard insertion, re-read the target text field (Accessibility API) after a delay (or on next dictation in the same app), **diff inserted text vs current text**, extract word-level substitutions, **filter with a common-word frequency list** so only distinctive terms are learned, store both the word and a misspelling→correction rule. Add a **review queue** ("Alowd learned: 'WhisperKit' — keep?") — something Wispr doesn't offer and which fits an open, trust-first product. Wispr does *not* do per-app vocabulary and contacts import is iOS-only — both are open flanks.
2. **True local-only privacy story**: Wispr is 100% cloud; superwhisper/VoiceInk are local but paid. "Free + open + zero network" is a positioning nobody fully owns except Handy (which has no dictionary/AI layer).
3. **Power-Mode-style per-app profiles** (frontmost-app bundle ID → mode mapping): cheap, delivers ~80% of Wispr's context-awareness value without screen reading.
4. **History dashboard with streak/WPM/word-count stats** — pure SwiftUI, big perceived-value multiplier.
5. **Handy-style model picker** including Turbo/Parakeet variants.
6. **Command Mode clone via Ollama**: selected text + spoken instruction → local LLM rewrite. Wispr charges $15/mo for this; local Ollama does it free.
7. **CSV dictionary import/export** — trivial, and lets users migrate *from* Wispr/superwhisper.

**Harder / lower priority**: full screen-text context reading (permission-heavy, Wispr/Aqua's moat), sub-500ms streaming insertion (Aqua), whisper-quiet-speech robustness (model-level), 100-language ensemble accuracy (cloud ensemble).
