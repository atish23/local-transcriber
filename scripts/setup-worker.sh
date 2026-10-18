#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
WORKER_DIR="$ROOT_DIR/transcriber-worker"
VENV_DIR="$WORKER_DIR/.venv"

echo "==> Setting up LocalTranscriber Python worker environment..."

# Find suitable Python 3.12+
PYTHON_BIN=""
for candidate in python3.13 python3.12 python3.14 python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
        VERSION=$("$candidate" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        MAJOR=$(echo "$VERSION" | cut -d. -f1)
        MINOR=$(echo "$VERSION" | cut -d. -f2)
        if [ "$MAJOR" -eq 3 ] && [ "$MINOR" -ge 12 ]; then
            PYTHON_BIN=$(command -v "$candidate")
            echo "Found suitable Python: $PYTHON_BIN (version $VERSION)"
            break
        fi
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    echo "ERROR: Python 3.12 or newer is required." >&2
    echo "Install via Homebrew: brew install python@3.13" >&2
    exit 1
fi

if [ ! -d "$VENV_DIR" ]; then
    echo "Creating virtual environment at $VENV_DIR..."
    "$PYTHON_BIN" -m venv "$VENV_DIR"
else
    echo "Virtual environment already exists at $VENV_DIR."
fi

if [ -f "$VENV_DIR/bin/python" ] && "$VENV_DIR/bin/python" -c "import mlx_whisper, silero_vad" 2>/dev/null; then
    echo "Required packages already installed in venv."
else
    echo "Installing required packages in venv..."
    "$VENV_DIR/bin/pip" install mlx-whisper silero-vad soundfile numpy scipy || echo "Notice: pip install skipped or offline. Will use fallback or retry on first online run."
fi

echo "==> Worker environment setup complete!"
echo "Python venv binary: $VENV_DIR/bin/python"
