# Meeting Copilot P0

A macOS companion for Webex meetings. It captures system audio, transcribes
English speech, automatically explains it in Chinese, searches files selected
for the meeting, and produces a short English reply when the other participant
asks a question or expects a response.

## Run

```bash
zsh scripts/build-app.sh
open "build/Meeting Copilot.app"
```

Before first launch, run:

```bash
zsh scripts/setup-whisper.sh
```

This installs whisper.cpp and downloads `ggml-large-v3-turbo.bin` to the app's
Application Support directory.

On first launch:

1. Allow Screen & System Audio Recording when macOS asks.
2. Open **Meeting Copilot > Settings**, enter a DeepSeek API key, and save it.
   The key is stored in macOS Keychain and is not written to files.
3. Add meeting files, start the meeting, and play Webex audio.

The app captures the primary display's system audio and transcribes five-second
segments locally with Whisper large-v3-turbo. Temporary WAV segments are deleted
immediately after transcription. It does not save raw audio,
join Webex, send chat messages, or speak on the user's behalf.

Automatic analysis runs after a short pause in speech. It keeps the six most
recent analyzed utterances as temporary in-memory context and clears them when
the app process exits.

## Supported meeting files

- PDF
- HTML / HTM
- Markdown / TXT / RTF / CSV
- DOCX
- PPTX
- XLSX

Office support is intentionally lightweight for P0: visible XML text is indexed,
while exact visual layout and formulas are not interpreted.

HTML support indexes visible static text and removes scripts, styles, comments,
and markup. Content created only after JavaScript runs is not included.

## Tests

```bash
swift test
```
