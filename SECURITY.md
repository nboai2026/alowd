# Security Policy

## Reporting a vulnerability

Please report security or privacy issues by opening a [GitHub security advisory](../../security/advisories/new), or a regular issue if the problem is not sensitive. Expect a first response within a week.

## Scope

Alowd runs entirely on the user's machine, so the interesting surfaces are local:

- **Accessibility reads.** Alowd reads the text field it pasted into, once, to learn corrected words (Settings → Privacy can disable this). It refuses when the frontmost app changed, when the element is a secure text field, when macOS secure input is active, or when the field no longer contains the inserted text — and it only learns from edits inside the dictated text, never from content typed before or after it. Ways to defeat those guards are in scope.
- **Clipboard.** Transcripts transit the general pasteboard (marked with nspasteboard.org transient/concealed types) and the previous contents — all item types — are restored; when the synthetic paste fails, the transcript is cleared after at most 60 seconds. Paths that leave sensitive text on the clipboard beyond that are in scope.
- **Network egress.** The only expected traffic is the user-triggered model download from `huggingface.co` and, if enabled, Ollama on `127.0.0.1`. Any other egress, or a bypass of the localhost restriction, is in scope.
- **Data at rest.** History, dictionary, and snippets are plaintext in `~/Alowd/`. This is documented and intended; unexpected data appearing there (or in profile exports) is in scope.
- **Prompt injection** into the optional Ollama rewrite, via dictated text or imported dictionary entries.

Out of scope: an attacker who already has code execution or full disk access as the user, and the absence of notarization on locally built bundles.
