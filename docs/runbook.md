# Alowd Runbook

## Install On A Mac

1. Install the Alowd app.
2. Launch it once.
3. Grant microphone permission.
4. Grant accessibility permission.
5. Alowd registers `Control` + `Option` + `Space` as its default global dictation toggle. This uses the macOS registered-hotkey API and does not need Input Monitoring.
6. Confirm `~/Alowd/` exists.

## Optional Ollama Local Rewrite

Ollama is optional. WhisperKit hears the audio. Ollama rewrites transcript text into the casual voice, professional voice, or custom prompt styles.

1. Install Ollama on this Mac.
2. Pull your selected local model.
3. Confirm Ollama is listening on `http://127.0.0.1:11434`.
4. Enable Ollama rewrite in Alowd settings.
5. Raw mode never uses Ollama.

## Local WhisperKit Model

Alowd installs and checks its recommended WhisperKit model from the menu bar. Select **Install Recommended WhisperKit Model** and keep Alowd open until the status says the local model is ready. This is a one-time, user-triggered download; normal dictation never downloads models.

Model files, including the WhisperKit download cache and tokenizer, stay in:

```text
~/Alowd/models/whisperkit
```

The app validates the required Core ML bundles before it allows transcription and loads the resolved model directory locally. Do not leave `whisperkit-cli --stream` running; Alowd does not need it for setup or dictation.

## Move To Another Mac

1. Export profile from the first Mac.
2. Install Alowd on the second Mac.
3. Import the exported profile.
4. Reinstall local STT/Ollama models if model files were not included.
5. Test insertion in TextEdit, a browser text field, and a terminal.

## Privacy Defaults

- No cloud account.
- No raw audio retention by default.
- No background keylogger.
- Dictionary learning comes from accepted corrections, selected text, and explicit writing samples.
- Transcript history is stored as plain (unencrypted) JSON at `~/Alowd/data/history.json`.
- Profile exports include transcript history and learned vocabulary — treat exported files as personal data.
- Inserted text transits the system clipboard briefly before the previous clipboard contents are restored, so clipboard managers may capture dictated text.
