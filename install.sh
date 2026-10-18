#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"

echo "=========================================================="
echo "  LocalTranscriber: 1-Click Setup & Global Installation   "
echo "=========================================================="

# 1. Check Apple Silicon architecture
ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ]; then
    echo "ERROR: LocalTranscriber requires Apple Silicon (arm64). Detected: $ARCH" >&2
    exit 1
fi

# 2. Check macOS version (macOS 15+)
OS_VERSION="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$OS_VERSION" -lt 15 ]; then
    echo "ERROR: LocalTranscriber requires macOS 15 (Sequoia) or newer. Detected: macOS $(sw_vers -productVersion)" >&2
    exit 1
fi

# 3. Setup Python worker virtual environment
echo ""
echo "==> Step 1/3: Setting up Python worker environment..."
bash "$REPO_DIR/scripts/setup-worker.sh"

# 4. Build optimized release binary
echo ""
echo "==> Step 2/3: Compiling optimized release binary..."
export TMPDIR="/tmp"
export SWIFT_MODULE_CACHE_PATH="/tmp/ModuleCache"
export CLANG_MODULE_CACHE_PATH="/tmp/ModuleCache"
swift build -c release --disable-sandbox --package-path "$REPO_DIR"

RELEASE_BIN="$REPO_DIR/.build/release/LocalTranscriber"
if [ ! -f "$RELEASE_BIN" ]; then
    echo "ERROR: Build failed. Could not find $RELEASE_BIN" >&2
    exit 1
fi

# 5. Install global CLI shortcuts into ~/.local/bin
echo ""
echo "==> Step 3/3: Installing global commands to $BIN_DIR..."
mkdir -p "$BIN_DIR"

# 5a. The 'record' shortcut command
cat << 'EOF' > "$BIN_DIR/record"
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Path to compiled release binary
BIN_PATH="__RELEASE_BIN_PLACEHOLDER__"
if [ ! -f "$BIN_PATH" ]; then
    echo "Error: LocalTranscriber binary not found at $BIN_PATH. Please re-run install.sh." >&2
    exit 1
fi
exec "$BIN_PATH" record "$@"
EOF
sed -i '' "s|__RELEASE_BIN_PLACEHOLDER__|$RELEASE_BIN|g" "$BIN_DIR/record"
chmod +x "$BIN_DIR/record"

# 5b. The 'transcribe' general command
cat << 'EOF' > "$BIN_DIR/transcribe"
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_PATH="__RELEASE_BIN_PLACEHOLDER__"
if [ ! -f "$BIN_PATH" ]; then
    echo "Error: LocalTranscriber binary not found at $BIN_PATH. Please re-run install.sh." >&2
    exit 1
fi
exec "$BIN_PATH" "$@"
EOF
sed -i '' "s|__RELEASE_BIN_PLACEHOLDER__|$RELEASE_BIN|g" "$BIN_DIR/transcribe"
chmod +x "$BIN_DIR/transcribe"

# 5c. The 'local-transcriber' command
ln -sf "$BIN_DIR/transcribe" "$BIN_DIR/local-transcriber"

# 6. Ensure ~/.local/bin is in PATH in shell config
SHELL_CONFIG=""
if [ -f "$HOME/.zshrc" ]; then
    SHELL_CONFIG="$HOME/.zshrc"
elif [ -f "$HOME/.bash_profile" ]; then
    SHELL_CONFIG="$HOME/.bash_profile"
elif [ -f "$HOME/.bashrc" ]; then
    SHELL_CONFIG="$HOME/.bashrc"
fi

if [ -n "$SHELL_CONFIG" ]; then
    if ! grep -q '\.local/bin' "$SHELL_CONFIG" 2>/dev/null; then
        echo "" >> "$SHELL_CONFIG"
        echo '# Added by LocalTranscriber installer' >> "$SHELL_CONFIG"
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_CONFIG"
        echo "==> Added $BIN_DIR to $SHELL_CONFIG"
    fi
fi

echo ""
echo "=========================================================="
echo "  Installation Successful!                                "
echo "=========================================================="
echo ""
echo "You can now run from ANY directory in your terminal:"
echo ""
echo "  record en                        # Record in English"
echo "  record hi                        # Record in Hindi"
echo "  record mr                        # Record in Marathi"
echo "  record en --title \"Team Sync\"    # With custom title"
echo "  record en --live-only            # Fast live preview only"
echo "  transcribe sessions              # Search previous transcripts"
echo "  transcribe finalize-pending      # Process queued final passes"
echo ""
echo "First-time Note:"
echo "macOS will ask for Microphone and Screen Recording permission on your"
echo "first recording. Grant both in System Settings -> Privacy & Security."
echo "=========================================================="
