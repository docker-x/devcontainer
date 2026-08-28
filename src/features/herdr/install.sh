#!/bin/bash
set -e

# Herdr Installation Script (non-interactive)

VERSION=${VERSION:-"latest"}

REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-root}}"
REMOTE_USER_HOME="${_REMOTE_USER_HOME:-$(getent passwd "$REMOTE_USER" 2>/dev/null | cut -d: -f6)}"
AGENT_DIR="${AGENT_CONFIG_DIR:-/usr/local/share/agent-config}/herdr"

echo "Installing Herdr (version: ${VERSION})..."

# Install curl if not available
if ! command -v curl &> /dev/null; then
    apt-get update -y && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
fi

# Try npm install first; fall back to the curl install script if npm is
# unavailable or the package install fails.
HERDR_INSTALLED=0

if command -v npm &> /dev/null; then
    set +e
    if [[ "$VERSION" == "latest" || -z "$VERSION" ]]; then
        npm install -g herdr
    else
        npm install -g herdr@"${VERSION}"
    fi
    NPM_RC=$?
    set -e
    if [[ $NPM_RC -eq 0 ]]; then
        HERDR_INSTALLED=1
        echo "Herdr installed via npm"
    else
        echo "npm install of herdr failed (exit ${NPM_RC}); falling back to install script"
    fi
fi

if [[ $HERDR_INSTALLED -eq 0 ]]; then
    set +e
    curl -fsSL https://herdr.ai/install.sh -o /tmp/herdr-install.sh
    CURL_RC=$?
    set -e
    if [[ $CURL_RC -ne 0 ]]; then
        rm -f /tmp/herdr-install.sh
        echo "Error: Herdr install script download failed (exit ${CURL_RC}) and npm was unavailable" >&2
        exit 1
    fi
    bash /tmp/herdr-install.sh --version "${VERSION:-latest}"
    CURL_RC=$?
    rm -f /tmp/herdr-install.sh
    set -e
    if [[ $CURL_RC -ne 0 ]]; then
        echo "Error: Herdr install script failed (exit ${CURL_RC}) and npm was unavailable" >&2
        exit 1
    fi
    echo "Herdr installed via install script"
fi

# Locate the installed binary and copy it to /usr/local/bin for system-wide access
HERDR_BIN="$(command -v herdr || true)"
if [[ -z "$HERDR_BIN" ]]; then
    HERDR_BIN="$HOME/.local/bin/herdr"
fi

if [[ ! -x "$HERDR_BIN" ]]; then
    echo "Warning: Herdr binary not found at $HERDR_BIN — herdr may not be published yet" >&2
    echo "Herdr feature installed (configuration only). Binary will be available when herdr is published."
    # Still set up the agent config dir so herdr can use it when available
    mkdir -p "$AGENT_DIR"
    if id -u "$REMOTE_USER" >/dev/null 2>&1; then
        chown -R "$REMOTE_USER:" "$AGENT_DIR"
    fi
    if [ -d "$REMOTE_USER_HOME" ]; then
        for target in "$REMOTE_USER_HOME/.herdr" "$REMOTE_USER_HOME/.config/herdr"; do
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
    echo "Herdr feature installed successfully (configuration only, binary pending publication)"
    exit 0
fi

cp "$HERDR_BIN" /usr/local/bin/herdr
chmod +x /usr/local/bin/herdr
echo "Herdr copied to /usr/local/bin/herdr"

# Shared agent config
mkdir -p "$AGENT_DIR"
if id -u "$REMOTE_USER" >/dev/null 2>&1; then
    chown -R "$REMOTE_USER:" "$AGENT_DIR"
fi

if [ -d "$REMOTE_USER_HOME" ]; then
    for target in "$REMOTE_USER_HOME/.herdr" "$REMOTE_USER_HOME/.config/herdr"; do
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
if command -v herdr >/dev/null 2>&1; then
    OUT=$(herdr --version 2>&1)
    RC=$?
    if [[ $RC -eq 0 ]]; then
        echo "Herdr version: ${OUT}"
    else
        echo "Herdr: version check skipped (exit ${RC})"
    fi
else
    echo "Herdr: binary not on PATH; skipping version check"
fi
set -e

echo "Herdr installed successfully!"
