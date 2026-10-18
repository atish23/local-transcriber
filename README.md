# LocalTranscriber

A private macOS command-line tool. It records your microphone and system audio (the other side of a call) simultaneously using ScreenCaptureKit, transcribes both locally on Apple Silicon with Whisper (MLX), and files verbatim Markdown and JSON twin transcripts into your LLM wiki or Application Support folder.

No audio or text ever leaves the machine.

---

## Architecture Overview

LocalTranscriber uses a two-process architecture talking over stdin/stdout with one JSON object per line:

```
              Swift CLI (LocalTranscriber)                       Python Worker (worker.py)
┌───────────────────────────────────────────────┐          ┌────────────────────────────────┐
│ CaptureEngine (ScreenCaptureKit)              │          │ mlx_whisper (Apple GPU / Metal)│
│   system audio + mic, 48 kHz stereo           │          │ silero-vad (energy fallback)   │
│        │ AudioNormalizer -> 16 kHz mono float │          │ vocabulary.json                │
│        ▼                                      │          │ hallucination + repeat filters │
│ AudioAligner  (one shared timeline)           │          └──────────────▲─────────────────┘
│        ▼                                      │   JSON line request     │ JSON line response
│ AudioChunker  (per source, 28 s windows)      │ ────────────────────────┘
│        ▼                                      │   WorkerClient (Process + Pipes + timeouts)
│ RecordingSession (queue, live segments)       │
│        ▼  Ctrl-C                              │
│ FinalPassRunner (2 workers in parallel)       │
│        ▼                                      │
│ TranscriptSegment.merged (echo removal)       │
│        ▼                                      │
│ WikiFiler -> raw/misc/<stem>.md + .json       │
│ PendingIngestQueue / PendingFinalPassQueue    │
└───────────────────────────────────────────────┘
```

### Why Two Processes?
- **MLX Whisper** runs with maximum performance on Apple Silicon via Python.
- **ScreenCaptureKit** is Apple's modern, Swift-native capture framework.
- Running the Whisper inference engine in a separate worker process protects audio capture from memory pressure or model download interruptions.

---

## Key Features

1. **Strict Channel Separation & Acoustic Echo Cancellation**
   - Microphone and system audio stay completely isolated until the final merge.
   - A microphone segment is dropped if 80% or more of its words match system audio around the same time (preventing speaker bleed/echo).
2. **Two-Pass Transcription**
   - **Live Pass**: Chunks are processed by `whisper-large-v3-turbo` for immediate terminal preview.
   - **Final Pass**: On Ctrl-C, full per-source audio streams are transcribed concurrently with `whisper-large-v3` for maximum accuracy.
3. **Adaptive Wiki Root Detection**
   - Automatically detects your LLM wiki at `~/Documents/LLM WIKI` or `~/Documents/llm-wiki`, with environment variable (`LOCAL_TRANSCRIBER_WIKI_ROOT`) and CLI (`--wiki-root`) overrides.
   - Gracefully falls back to `~/Library/Application Support/LocalTranscriber/transcripts` if no wiki is found or if `--no-wiki` is specified.
4. **Speaker Attribution (`--speaker-labels`)**
   - Optional attribution tags (`**[You]**` and `**[Remote / System]**`) in Markdown and source fields in the JSON twin.
5. **Language & Task Controls (`--task transcribe|translate`)**
   - Default `--task transcribe` preserves the original spoken language (English, Hindi, Marathi, etc.).
   - Use `--task translate` if you want automatic translation to English.
6. **Streaming Audio Resilience**
   - Streams WAV data to disk incrementally (`session-microphone.wav`, `session-device.wav`) as it is captured. A laptop sleep or interruption loses no captured audio.
7. **Durable Queues**
   - `finalize-pending`: Defer the heavy final pass when you are on battery or need to move quickly.
   - `ingest-pending`: Queue transcripts for ingestion into your knowledge base via `claude "/ingest <path>"`.

---

## What is an LLM Wiki and Why Ingest Transcripts?

### The LLM Wiki Pattern
This tool is designed to feed directly into an AI-maintained personal knowledge base, following [Andrej Karpathy's LLM Wiki pattern](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f).

Unlike traditional search or RAG (Retrieval-Augmented Generation), which searches noisy raw documents on the fly for every question, an LLM Wiki **compiles and synthesizes knowledge once** into a persistent, interlinked set of Markdown pages:
- **`raw/` (Input Layer)**: Immutable source materials (articles, book excerpts, meeting transcripts). You drop sources here; they are never modified.
- **`wiki/` (Compiled Knowledge Layer)**: Structured encyclopedia pages organized by concepts, entities, and projects. AI assistants (such as Claude, Antigravity, or Codex) read the raw sources and maintain these pages.

### Why Ingest Call Transcripts?
Real-time meetings, pairing sessions, and architecture reviews contain critical context: architectural trade-offs, system constraints, task assignments, and technical decisions. However:
- Taking detailed manual notes during complex technical discussions is distracting.
- Unstructured notes typically get lost or buried in chat channels.

LocalTranscriber bridges spoken discussions with your permanent knowledge base:
1. **Verbatim Local Capture**: It records both sides of your call on-device and files an accurate transcript into `llm-wiki/raw/misc/local-transcript-YYYY-MM-DD-HHMM-<slug>.md`.
2. **Automated Synthesis via `/ingest`**: Running `claude "/ingest <path>"` (or `swift run LocalTranscriber ingest-pending`) instructs the LLM to process the raw transcript, extract key architectural decisions, update relevant project pages, create new entity records, and link new facts to past context.
3. **Zero-Overhead Memory**: Your knowledge base compounds and gets smarter after every call, with zero manual note-taking friction.

---

## Setup & Prerequisites

### Prerequisites
- Apple Silicon Mac (M1/M2/M3/M4) running macOS 15 or newer.
- Swift 6 toolchain (Xcode or Command Line Tools).
- Python 3.12 or newer (`brew install python@3.13`).
- About 5 GB free disk space for Hugging Face model cache.

### Installation
```bash
# 1. Clone or navigate to the repository
cd ~/Documents/local-transcriber

# 2. Run the worker setup script (creates virtual environment and installs dependencies)
bash scripts/setup-worker.sh

# 3. Build the Swift CLI binary
swift build
```

---

## Permissions

LocalTranscriber embeds `Info.plist` with bundle ID `local.atish.LocalTranscriber`. On first recording, macOS will prompt for:
- **Microphone**: To capture your voice.
- **Screen Recording**: Required by macOS ScreenCaptureKit to capture system audio.

If prompted, grant access under **System Settings -> Privacy & Security -> Microphone** and **Screen Recording**.

---

## Usage

### 1. Record a Call
```bash
# Standard call recording
swift run LocalTranscriber record --title "Team Sync" --language auto

# With speaker labels and auto-translation
swift run LocalTranscriber record --title "Design Review" --speaker-labels --task translate

# Skip final pass and file live preview directly
swift run LocalTranscriber record --title "Quick Standup" --live-only
```

During recording:
- Live transcription chunks appear in your terminal.
- Press **Ctrl-C** when finished.
- When prompted `Run authoritative final pass with whisper-large-v3? [Y/n/later]:`:
  - `Y` (or Enter): Runs parallel final passes and files the transcript.
  - `n`: Files the live preview transcript directly.
  - `later`: Saves audio and metadata to the deferred queue.

### 2. Manage Queued Jobs
```bash
# Process deferred final passes
swift run LocalTranscriber finalize-pending

# Replay queued claude /ingest commands
swift run LocalTranscriber ingest-pending
```

### 3. Search and Inspect Past Sessions
```bash
# List all sessions
swift run LocalTranscriber sessions

# Search by title or transcript content
swift run LocalTranscriber sessions --query "standup"
```

### 4. Custom Private Vocabulary (Git-Ignored)
You can create `transcriber-worker/vocabulary.local.json` to bias Whisper with your own private project terms, abbreviations, and mishearing corrections without committing them to version control:

```json
{
  "prompt_terms": ["MyProject", "CustomTerm"],
  "corrections": {
    "my project": "MyProject"
  },
  "casing_stoplist": []
}
```

### 5. Audio Cleanup
```bash
# Prune preserved audio recordings older than 14 days
swift run LocalTranscriber clean-audio --days 14
```

---

## Running Tests

Both test suites run completely offline and in fake mode without requiring GPU weight downloads:

```bash
# Run Swift unit and integration tests (15 tests)
swift test

# Run Python worker tests (9 tests)
python3 transcriber-worker/test_worker.py
```
