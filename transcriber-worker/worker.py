#!/usr/bin/env python3
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

FAKE_MODE = os.environ.get("LOCAL_TRANSCRIBER_FAKE", "0") == "1"
DEFAULT_LIVE_MODEL = os.environ.get("LOCAL_TRANSCRIBER_MODEL", "mlx-community/whisper-large-v3-turbo")
DEFAULT_FINAL_MODEL = os.environ.get("LOCAL_TRANSCRIBER_FINAL_MODEL", "mlx-community/whisper-large-v3")

HALLUCINATION_PATTERNS = [
    r"^\s*thank you(\s+very much)?[\.!]?\s*$",
    r"^\s*thank you for watching[\.!]?\s*$",
    r"^\s*thanks for watching[\.!]?\s*$",
    r"^\s*please subscribe[\.!]?\s*$",
    r"^\s*subtitles by\b.*$",
    r"^\s*transcription by\b.*$",
    r"^\s*bye[\.!]?\s*$",
    r"^\s*you\s*$",
    r"^\s*(\.\s*)+$",
    r"^\s*amara\.org\b.*$",
]

def load_vocabulary() -> Dict[str, Any]:
    base: Dict[str, Any] = {"prompt_terms": [], "corrections": {}, "casing_stoplist": []}
    vocab_file = Path(__file__).parent / "vocabulary.json"
    if vocab_file.exists():
        try:
            with open(vocab_file, "r", encoding="utf-8") as f:
                data = json.load(f)
                base["prompt_terms"].extend(data.get("prompt_terms", []))
                base["corrections"].update(data.get("corrections", {}))
                base["casing_stoplist"].extend(data.get("casing_stoplist", []))
        except Exception as e:
            sys.stderr.write(f"Warning: Failed to load vocabulary.json: {e}\n")

    # Merge optional local git-ignored vocabulary
    local_vocab = Path(__file__).parent / "vocabulary.local.json"
    if local_vocab.exists():
        try:
            with open(local_vocab, "r", encoding="utf-8") as f:
                local_data = json.load(f)
                base["prompt_terms"].extend(local_data.get("prompt_terms", []))
                base["corrections"].update(local_data.get("corrections", {}))
                base["casing_stoplist"].extend(local_data.get("casing_stoplist", []))
        except Exception as e:
            sys.stderr.write(f"Warning: Failed to load vocabulary.local.json: {e}\n")

    return base

VOCABULARY = load_vocabulary()

def collapse_repeated_phrase(text: str) -> str:
    if not text:
        return ""
    # Collapse 3 or more repeated identical words or phrases
    pattern = r"\b(\w+(\s+\w+){0,3})\b(\s+\1\b){2,}"
    collapsed = re.sub(pattern, r"\1", text, flags=re.IGNORECASE)
    return collapsed.strip()

def is_hallucination(text: str) -> bool:
    clean = text.strip()
    if not clean:
        return True
    for pattern in HALLUCINATION_PATTERNS:
        if re.search(pattern, clean, re.IGNORECASE):
            return True
    return False

def apply_vocabulary_corrections(text: str, corrections: Dict[str, str]) -> str:
    result = text
    for target, replacement in corrections.items():
        pattern = r"\b" + re.escape(target) + r"\b"
        result = re.sub(pattern, replacement, result, flags=re.IGNORECASE)
    return result

def clean_transcript_text(text: str, corrections: Dict[str, str]) -> str:
    collapsed = collapse_repeated_phrase(text)
    if is_hallucination(collapsed):
        return ""
    corrected = apply_vocabulary_corrections(collapsed, corrections)
    return corrected.strip()

class MLXTranscriber:
    def __init__(self, model_name: str):
        self.model_name = model_name
        self.whisper_module = None
        if not FAKE_MODE:
            try:
                import mlx_whisper
                self.whisper_module = mlx_whisper
            except ImportError:
                sys.stderr.write("mlx_whisper not found, falling back to fake mode\n")
                self.whisper_module = None

    def transcribe(
        self,
        audio_path: str,
        language: Optional[str] = None,
        task: str = "transcribe",
        initial_prompt: Optional[str] = None
    ) -> List[Dict[str, Any]]:
        if FAKE_MODE or self.whisper_module is None:
            # Deterministic fake output for testing
            stem = Path(audio_path).stem
            return [
                {
                    "start": 0.0,
                    "end": 2.5,
                    "text": f"This is a simulated transcription for {stem}."
                }
            ]

        lang_arg = None if (language in [None, "auto"]) else language
        args = {
            "path_or_hf_repo": self.model_name,
            "condition_on_previous_text": False,
            "task": task,
        }
        if lang_arg:
            args["language"] = lang_arg
        if initial_prompt:
            args["initial_prompt"] = initial_prompt

        result = self.whisper_module.transcribe(audio_path, **args)
        raw_segments = result.get("segments", [])
        output = []
        for seg in raw_segments:
            output.append({
                "start": float(seg.get("start", 0.0)),
                "end": float(seg.get("end", 0.0)),
                "text": seg.get("text", "").strip()
            })
        return output

def build_initial_prompt(prompt_terms: List[str]) -> str:
    if not prompt_terms:
        return ""
    return ", ".join(prompt_terms) + "."

def main():
    corrections = VOCABULARY.get("corrections", {})
    prompt_terms = VOCABULARY.get("prompt_terms", [])
    initial_prompt = build_initial_prompt(prompt_terms)

    # Initialize transcriber instance
    model_name = os.environ.get("LOCAL_TRANSCRIBER_MODEL", DEFAULT_LIVE_MODEL)
    transcriber = MLXTranscriber(model_name)

    # Signal ready to parent process
    sys.stdout.write(json.dumps({"ready": True}) + "\n")
    sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception as e:
            sys.stdout.write(json.dumps({"status": "error", "message": f"Invalid JSON: {e}"}) + "\n")
            sys.stdout.flush()
            continue

        command = req.get("command")
        if command == "ping":
            sys.stdout.write(json.dumps({"status": "ok"}) + "\n")
            sys.stdout.flush()
            continue

        if command in ("transcribe_chunk", "transcribe_file"):
            audio_path = req.get("audio_path")
            source = req.get("source", "microphone")
            language = req.get("language", "auto")
            task = req.get("task", "transcribe")
            discard_before = float(req.get("discard_before", 0.0))

            if not audio_path or not os.path.exists(audio_path):
                sys.stdout.write(json.dumps({"status": "error", "message": f"Audio file not found: {audio_path}"}) + "\n")
                sys.stdout.flush()
                continue

            try:
                raw_segments = transcriber.transcribe(
                    audio_path=audio_path,
                    language=language,
                    task=task,
                    initial_prompt=initial_prompt
                )

                filtered_segments = []
                for seg in raw_segments:
                    start = seg["start"]
                    end = seg["end"]
                    midpoint = (start + end) / 2.0

                    # Overlap handling: skip segments whose midpoint is within discarded overlap
                    if midpoint < discard_before:
                        continue

                    cleaned_text = clean_transcript_text(seg["text"], corrections)
                    if not cleaned_text:
                        continue

                    filtered_segments.append({
                        "start": start,
                        "end": end,
                        "text": cleaned_text,
                        "source": source
                    })

                sys.stdout.write(json.dumps({
                    "status": "ok",
                    "segments": filtered_segments
                }) + "\n")
                sys.stdout.flush()

            except Exception as e:
                sys.stdout.write(json.dumps({"status": "error", "message": str(e)}) + "\n")
                sys.stdout.flush()
            continue

        sys.stdout.write(json.dumps({"status": "error", "message": f"Unknown command: {command}"}) + "\n")
        sys.stdout.flush()

if __name__ == "__main__":
    main()
