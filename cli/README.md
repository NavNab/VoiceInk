# voiceink-cli

Bash CLI for VoiceInk — transcribes audio files, records from mic, or reads
from stdin using VoiceInk's already-downloaded local Whisper models.

## Requirements

- [VoiceInk](https://tryvoiceink.com) installed with at least one model downloaded
- `whisper-cli`: `brew install whisper-cpp`
- `ffmpeg`: `brew install ffmpeg`

## Install

```bash
# From the klyr repo root:
ln -sf "$(pwd)/scripts/voiceink-cli/voiceink-cli.sh" ~/bin/voiceink-cli
```

Make sure `~/bin` is in your `$PATH`.

## Usage

```bash
# Transcribe a file (plain text to stdout)
voiceink-cli meeting.m4a

# Transcribe to markdown file with frontmatter
voiceink-cli meeting.m4a --format md --output ~/notes/meeting.md

# Transcribe to JSON
voiceink-cli meeting.m4a --format json

# Record from mic (Ctrl+C to stop)
voiceink-cli

# Record to markdown file
voiceink-cli --format md --output ~/notes/voice-memo.md

# Pipe audio in
ffmpeg -i podcast.mp3 -f wav - | voiceink-cli --format json

# Choose a specific model
voiceink-cli interview.wav --model ggml-large-v3-turbo-q5_0

# List available models
voiceink-cli --list-models
```

## Output Formats

| Format | Description |
|--------|-------------|
| `txt` (default) | Plain transcript to stdout |
| `md` | Markdown with YAML frontmatter (date, source, duration, model, language) |
| `json` | Structured JSON object |

Progress messages go to stderr; transcript goes to stdout — pipe-safe.
