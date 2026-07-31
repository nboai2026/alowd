# Alowd

**Talk instead of typing, on any Mac app — without a single byte leaving your machine.**

Press a hotkey, speak, and your words appear wherever your cursor is. Alowd transcribes on-device with [WhisperKit](https://github.com/argmaxinc/WhisperKit), learns the words you actually use, and costs nothing. No account, no subscription, no audio uploaded anywhere.

<!-- TODO before publishing: a ~15s demo GIF here. It is the single highest-converting
     element of this README — record dictating into Slack or a code editor, showing the
     overlay with live text, then the pasted result. -->

![Platform](https://img.shields.io/badge/macOS-14%2B-black)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![License](https://img.shields.io/badge/license-MIT-blue)
![Offline](https://img.shields.io/badge/network-none-brightgreen)

## Why

Dictation on macOS makes you pick between three bad options: Apple's built-in dictation has no custom vocabulary and no formatting; the good cloud apps stream your microphone to someone else's servers for $15/month; the good local apps cost money and stop short of learning your vocabulary.

Alowd is free, open source, and fully offline — and it still does the thing that makes paid dictation worth paying for: **it learns the words it keeps getting wrong**.

## Features

- **Dictate anywhere** — a global hotkey inserts text into whichever app has focus. Toggle mode or hold-to-talk.
- **Live overlay** — a floating pill shows input levels and a live partial transcript while you speak, so you always know it is listening.
- **Learns your vocabulary** — after inserting, Alowd checks whether you corrected a word, and offers to remember it. Names, jargon, file paths, product names. Every suggestion is reviewed by you before it is kept.
- **Personal dictionary** — add words and phrases by hand, define misspelling → correction rules, import/export CSV.
- **History dashboard** — every dictation, grouped by day, searchable, with word count and streak stats. Nothing you dictate is ever lost, even if pasting fails.
- **Writing modes** — raw, casual, professional, or agent-prompt (which preserves paths, commands, and identifiers verbatim).
- **Any language** — Whisper is multilingual. English, French, Spanish, Portuguese and German are in the picker (auto-detect too); dictate in your language and get it back, or have it translate to English as you speak. Auto-detect can misjudge short or noisy clips — pick the language explicitly if you always speak the same one.
- **Model picker** — from `base` (fast) to `large-v3-turbo` (most accurate).
- **Optional local rewrite** — if you run [Ollama](https://ollama.com), Alowd can clean up transcripts with a local LLM. Localhost only; falls back instantly if it is slow or unavailable.

## Install

Requires macOS 14+ (Apple Silicon strongly recommended) and Xcode 16+ to build.

```bash
git clone https://github.com/YOUR-USERNAME/alowd.git
cd alowd
Scripts/package-app.sh
```

Drag `dist/Alowd.app` to `/Applications` and launch it. Alowd lives in your menu bar; the default hotkey is `Control` + `Option` + `Space`.

On first launch, pick **Install Recommended WhisperKit Model** from the menu and wait for the status to say it is ready. This one-time download from `huggingface.co` is the only network request Alowd ever makes.

<details>
<summary>Running from source, and notes on unsigned builds</summary>

```bash
swift build && swift run AlowdApp
swift test
```

Because the bundle is ad-hoc signed rather than notarized, macOS may block the first double-click: right-click the app and choose **Open**, then confirm. macOS ties Microphone and Accessibility permissions to an app's signature, and every rebuild produces a new ad-hoc signature — so after rebuilding, dictation transcribes but silently stops pasting. Toggling the checkbox is not enough: **remove Alowd from System Settings → Privacy & Security → Accessibility with the “–” button, then add the rebuilt `.app` again**, because the stale entry still looks enabled. Using the packaged `.app` (rather than `swift run`) keeps grants stable between rebuilds of the same binary.
</details>

## Permissions, and what Alowd deliberately does not ask for

| Permission | Why |
|---|---|
| **Microphone** | To record while you dictate. |
| **Accessibility** | To paste into the focused app, and to check whether you corrected a word. |

Alowd does **not** request Input Monitoring. The global hotkey uses Carbon's `RegisterEventHotKey`, which registers one specific key combination with the system rather than tapping the keyboard stream — **there is no keylogging capability anywhere in this codebase**, by construction rather than by promise.

## Privacy

The honest version, including the parts that are not perfect:

- **No network.** Transcription, rewriting, and learning all happen on your Mac. The only egress is the model download you trigger yourself, plus Ollama on `127.0.0.1` if you enable it. There is no telemetry, no analytics, no account.
- **Your data is plain files** in `~/Alowd/` — transcript history, dictionary, snippets. Readable by you, and by anything else with access to your home directory. Nothing is encrypted; treat it like your Documents folder.
- **Text passes through the clipboard.** Insertion writes to the pasteboard and synthesizes Cmd+V, restoring your previous clipboard (including images and files) afterward. Transcripts are marked with the [nspasteboard.org](http://nspasteboard.org) transient/concealed types so well-behaved clipboard managers skip recording them.
- **Vocabulary learning reads the field it pasted into**, once, shortly after inserting — and refuses to look if you have switched apps, if the field is a password field, if macOS secure input is active, or if the field no longer contains the text Alowd inserted. Only corrections *inside* the dictated text are ever considered; anything you type before or after it is ignored. Settings → Privacy turns the feature off entirely.
- **Raw audio is discarded** after transcription unless you turn retention on.

Found a security problem? Please open an issue, or see [SECURITY.md](SECURITY.md).

## How it compares

| | Alowd | Wispr Flow | superwhisper | Apple Dictation |
|---|---|---|---|---|
| Runs on-device | ✅ | ❌ cloud only | ✅ | ✅ |
| Price | Free, MIT | $15/mo | Paid tiers | Free |
| Custom dictionary | ✅ | ✅ | ✅ | ❌ |
| Learns from your corrections | ✅ | ✅ | ❌ | ❌ |
| History + stats | ✅ | ✅ | ✅ | ❌ |
| Live transcript overlay | ✅ | ✅ | ✅ | ✅ |
| Open source | ✅ | ❌ | ❌ | ❌ |

Wispr Flow is a genuinely good product and the inspiration for this one; it is a hosted service with a team behind it, and this is a free local alternative with different tradeoffs. Comparisons above reflect publicly documented features as of July 2026.

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). The codebase is small and layered: `Sources/AlowdCore` holds all logic behind protocol seams with fakes in tests, and `Sources/AlowdApp` is SwiftUI plus the composition root. `swift test` runs 136 tests and should stay green.

## Credits

Built on [WhisperKit](https://github.com/argmaxinc/WhisperKit) by [Argmax](https://www.takeargmax.com) (MIT), which does the hard part.

## License

MIT — see [LICENSE](LICENSE).
