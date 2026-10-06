# voiceink-cli (Parakeet)

Headless command-line transcriber that runs the same file-transcription pipeline as the
VoiceInk app with its FluidAudio engine (NVIDIA `parakeet-tdt-0.6b-v3`), fully local,
with no GUI interaction.

## Requirements

- macOS 14+, Apple Silicon recommended.
- The Parakeet model downloaded once in VoiceInk (Settings > AI Models). The CLI reads it
  from `~/Library/Application Support/FluidAudio/Models/` and never downloads anything.
- `ffmpeg` (optional): used only for containers AVFoundation cannot decode (mkv, webm, ...).

## Build and install

```bash
cd cli/parakeet
./install.sh                 # builds release and installs to ~/.local/share/voiceink-cli/bin
./install.sh /some/bin/dir   # or a custom directory
```

Then symlink the installed binary into a directory on `PATH`.

## Usage

```bash
voiceink-cli meeting.m4a                                   # plain text to stdout
voiceink-cli meeting.m4a -f srt -o meeting.srt             # subtitles with timestamps
voiceink-cli call.mp4 -f json -o call.json                 # text + timed segments
voiceink-cli *.mp3 -f txt -o transcripts/ --skip-existing  # batch, resumable
voiceink-cli interview.wav --lang fr                       # decoder script hint
```

Progress goes to stderr, transcripts to stdout or `--output`. Exit status is 0 when every
file succeeded, 1 when at least one failed (the batch continues), 2 on usage errors.

## Pipeline (mirrors the app)

1. Decode with `AVAudioFile`, resample to 16 kHz mono, average channels, peak-normalize
   each 50M-frame chunk, then quantize to Int16 and back (the app stores a WAV first).
2. Silero VAD (threshold 0.7) for audio of 20 s or more when VAD is enabled; speech
   regions are concatenated. Clips that fit in one 15 s window get 1 s of trailing silence.
3. `AsrManager.transcribe` (long audio is chunked by FluidAudio), then `TextNormalizer`.
4. Output filter (tag blocks, bracketed text, filler words), paragraph formatting, word
   replacements, punctuation/lowercase cleanup preferences.

Settings are read read-only from the app preferences (`com.prakashjoshipax.VoiceInk`),
falling back to the app defaults (VAD on, formatting on, filler removal on). Word
replacements are read from a temporary copy of the app's `dictionary.store`; the store
itself is never opened. Flags `--no-vad`, `--no-format`, `--keep-fillers` and
`--no-replacements` override them.

Differences from the app, all intentional:

- The app resamples with an `AVAudioConverter` input block that keeps returning the same
  buffer; the CLI feeds each chunk once and then signals end of stream.
- The app reads its intermediate WAV by skipping a fixed 44-byte header; the CLI works on
  the samples directly, so no header bytes are read as audio.
- JSON and SRT segments are built from token timings. With VAD, timings are mapped back
  through the speech regions, so timestamps refer to the original file.
- No AI enhancement, Power Mode, or history entry in the app.
