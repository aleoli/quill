# quill

A minimal, fully local macOS meeting recorder + transcriber. One menu-bar
click records your mic and all system audio as two separate tracks; when you
stop, quill transcribes both on-device and writes a speaker-tagged transcript.
Nothing ever leaves the machine.

Named for the feather. Sibling of [parrot](https://github.com/digimata/parrot), same skeleton: single
Swift binary, menu-bar tray, no app bundle.

## Install

```sh
cd quill
swift build -c release
sudo cp .build/release/quill /usr/local/bin/quill
quill install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

## How to use

1. **Run it** (`quill` in a terminal, or the LaunchAgent).
2. **Click the feather in the menu bar → Start recording.** First use prompts
   for microphone and System Audio Recording permissions. While recording, the
   icon turns red with a running elapsed counter, and macOS shows the purple
   recording indicator.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically (the menu shows progress); a notification fires when the
   transcript is ready.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `transcribe.log` | transcription progress/errors for this session |

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system is free two-party diarization — `me` vs `them` with no
speaker-identification model. CAF on purpose: unlike m4a, it needs no
finalization pass — if the process dies mid-meeting, everything already
written is still readable.

## Transcription

Built in, on-device, automatic. The default engine is **Parakeet TDT 0.6B v2**
(English) via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s
Core ML port — roughly 20 seconds per hour of audio on Apple Silicon. Models
(~600 MB) download once on first transcription; `quill doctor` tells you
whether they're already cached so you're never downloading after an important
meeting.

For multilingual audio, switch to the **Whisper** engine
([WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) / Core ML, running
on the Apple Neural Engine). Set `transcription.engine` to `"whisper"` in
config; the model defaults to `large-v3-v20240930_turbo` (~626 MB) and is
configurable. Whisper auto-detects the language per file, or you can force one
with `transcription.language`.

Each track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch (the filesystem is the queue: a session with `meta.json` but no
`transcript.json` is pending). Failures append to the session's
`transcribe.log` and never block later jobs.

The engine sits behind a small protocol; `parakeet` and `whisper` ship today.

## AI Analysis

After each transcript is written, quill can run an LLM to extract a
summary, action items, decisions, topics, Q&A, and keywords — then write
an Obsidian-style folder of Markdown notes inside the session directory.
Analysis is optional and works with any OpenAI-compatible endpoint: a local
[Ollama](https://ollama.com) server, OpenRouter, or OpenAI itself.

### Output layout

For a session `~/Recordings/2026.07.31-1400/`, analysis writes:

```text
2026.07.31-1400/
  2026.07.31-1400/                    # overview with Obsidian wiki-links
  2026.07.31-1400_Transcript.md       # transcript with timestamps
  AI_Summary.md
  Action_Items.md
  Key_Decisions.md
  Topics_Outline.md
  Questions_and_Answers.md
  Keywords.md
  analysis.log                        # per-session progress/errors
```

The overview note uses `[[...]]` wiki-links so Obsidian renders the whole
session as a navigable graph.

### Analysis config

Add an `analysis` and `llm` block to `~/.config/quill/config.json`:

```json
{
  "analysis": {
    "enabled": true,
    "sections": ["summary", "action_items", "decisions", "topics", "qa", "keywords"]
  },
  "llm": {
    "engine": "openai",
    "base_url": "http://localhost:11434/v1",
    "api_key": "",
    "model": "qwen3.6:35b",
    "temperature": 0.2,
    "max_tokens": 64000
  }
}
```

- `analysis.enabled` — set `false` to skip automatic analysis (default on).
  Recording and transcription still work.
- `analysis.sections` — which sections to generate. Defaults to all six:
  `summary`, `action_items`, `decisions`, `topics`, `qa`, `keywords`.
- `llm.engine` — `openai` (the only engine today; works with any
  OpenAI-compatible endpoint). Unknown values warn and fall back to openai.
- `llm.base_url` — the OpenAI-compatible API root. Default is a local Ollama
  server (`http://localhost:11434/v1`). For OpenAI, use
  `https://api.openai.com/v1`.
- `llm.api_key` — API key. Leave empty for local Ollama (no auth needed).
- `llm.model` — any model name the endpoint accepts: Ollama tags
  (`qwen3.6:35b`), OpenAI IDs (`gpt-4o`), etc.
- `llm.temperature` — sampling temperature (default 0.3).
- `llm.max_tokens` — max completion tokens (default 4096). Bump for long
  transcripts.

### Manual analysis

```sh
quill analyze <session-dir>           # analyze one session (uses config)
quill analyze <session-dir> --only summary,action_items
```

`quill doctor` checks that the LLM endpoint is reachable.

## Config

Optional, at `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": {
    "enabled": true,
    "engine": "parakeet",
    "model": "large-v3-v20240930_turbo",
    "language": "it"
  },
  "analysis": {
    "enabled": true,
    "sections": ["summary", "action_items", "decisions", "topics", "qa", "keywords"]
  },
  "llm": {
    "engine": "openai",
    "base_url": "http://localhost:11434/v1",
    "api_key": "",
    "model": "qwen3.6:35b",
    "temperature": 0.2,
    "max_tokens": 64000
  },
  "on_stop": "my-hook"
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `transcription.enabled` — set `false` to just record.
- `transcription.engine` — `parakeet` (default, English-only, fastest) or
  `whisper` (multilingual via WhisperKit / Core ML). Unknown values warn and
  fall back to parakeet.
- `transcription.model` — WhisperKit model name, only used when
  `engine == "whisper"`. Defaults to `large-v3-v20240930_turbo`. Any model in
  the `argmaxinc/whisperkit-coreml*` HuggingFace family works.
- `transcription.language` — optional ISO 639-1 code (e.g. `"it"`, `"en"`) to
  force for the whisper engine. Omit for per-file auto-detection. Ignored by
  parakeet (English-only).
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript is written** (or right after recording if
  transcription is disabled). Wire it to whatever comes next: summarization,
  filing, indexing.

## CLI

```sh
quill                        # run the menu-bar daemon (^C to quit)
quill run --out <dir>        # custom recordings root (default ~/Recordings)
quill doctor                 # check permissions, recordings folder, models, LLM
quill analyze <session-dir>  # run AI analysis on one session's transcript
quill install --launch-at-login
quill install --uninstall
```

## Stack

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **WhisperKit / argmax-oss-swift** — on-device Core ML transcription (whisper engine)
- **macpaw/OpenAI** — OpenAI-compatible LLM client for AI analysis (Ollama, OpenAI, OpenRouter)
- **NSStatusItem** — the whole UI

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- Parakeet v2 is English-only. Use the `whisper` engine for other languages.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.
