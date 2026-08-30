#!/bin/bash
set -e

# OpenAI Codex CLI Installation Script (non-interactive)

VERSION=${VERSION:-"latest"}

REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-root}}"
REMOTE_USER_HOME="${_REMOTE_USER_HOME:-$(getent passwd "$REMOTE_USER" 2>/dev/null | cut -d: -f6)}"
AGENT_DIR="${AGENT_CONFIG_DIR:-/usr/local/share/agent-config}/codex"

echo "Installing OpenAI Codex CLI (version: ${VERSION})..."

# Install curl and npm if not available
if ! command -v curl &> /dev/null; then
    apt-get update -y && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
fi

if ! command -v npm &> /dev/null; then
    echo "Error: npm is required to install Codex CLI. Add the node feature before this one." >&2
    exit 1
fi

# Install Codex CLI globally via npm
if [[ "$VERSION" == "latest" || -z "$VERSION" ]]; then
    npm install -g @openai/codex
else
    npm install -g @openai/codex@"${VERSION}"
fi

# Locate the installed binary and copy it to /usr/local/bin for system-wide access
CODEX_BIN="$(command -v codex || true)"
if [[ -z "$CODEX_BIN" ]]; then
    # npm global bin may not be on PATH during build; fall back to npm root
    NPM_GLOBAL_BIN="$(npm bin -g 2>/dev/null || true)"
    if [[ -z "$NPM_GLOBAL_BIN" ]]; then
        NPM_GLOBAL_BIN="$(npm config get prefix 2>/dev/null || true)/bin"
    fi
    CODEX_BIN="$NPM_GLOBAL_BIN/codex"
fi

if [[ ! -x "$CODEX_BIN" ]]; then
    echo "Codex CLI installation failed: binary not found at $CODEX_BIN" >&2
    exit 1
fi

cp "$CODEX_BIN" /usr/local/bin/codex
chmod +x /usr/local/bin/codex
echo "Codex CLI copied to /usr/local/bin/codex"

# Shared agent config
mkdir -p "$AGENT_DIR"
if id -u "$REMOTE_USER" >/dev/null 2>&1; then
    chown -R "$REMOTE_USER:" "$AGENT_DIR"
fi

if [ -d "$REMOTE_USER_HOME" ]; then
    for target in "$REMOTE_USER_HOME/.codex" "$REMOTE_USER_HOME/.config/codex"; do
        if [ -e "$target" ] && [ ! -L "$target" ]; then
            mv "$target" "$AGENT_DIR/$(basename "$target")-legacy"
        fi
        parent=$(dirname "$target")
        mkdir -p "$parent"
        rm -f "$target"
        if id -u "$REMOTE_USER" >/dev/null 2>&1; then
            chown "$REMOTE_USER:" "$parent" 2>/dev/null || true
            su -s /bin/bash - "$REMOTE_USER" -c "ln -sfn '$AGENT_DIR' '$target'" 2>/dev/null || true
        else
            ln -sfn "$AGENT_DIR" "$target"
        fi
    done
fi

# Verify installation (don't let version-check failures abort the build)
set +e
if command -v codex >/dev/null 2>&1; then
    OUT=$(codex --version 2>&1)
    RC=$?
    if [[ $RC -eq 0 ]]; then
        echo "Codex CLI version: ${OUT}"
    else
        echo "Codex CLI: version check skipped (exit ${RC})"
    fi
else
    echo "Codex CLI: binary not on PATH; skipping version check"
fi
set -e

echo "OpenAI Codex CLI installed successfully!"
