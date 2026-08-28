#!/bin/bash
set -e

# OpenCode AI Installation Script (non-interactive)

VERSION=${VERSION:-"latest"}
INSTALL_METHOD=${INSTALLMETHOD:-"npm"}

REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-root}}"
REMOTE_USER_HOME="${_REMOTE_USER_HOME:-$(getent passwd "$REMOTE_USER" 2>/dev/null | cut -d: -f6)}"
AGENT_DIR="${AGENT_CONFIG_DIR:-/usr/local/share/agent-config}/opencode"

echo "Installing OpenCode AI (method: ${INSTALL_METHOD}, version: ${VERSION})..."

# Install curl if not available
if ! command -v curl &> /dev/null; then
    apt-get update -y && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
fi

case "$INSTALL_METHOD" in
    npm)
        if ! command -v npm &> /dev/null; then
            echo "Error: npm is required for the npm install method. Add the node feature before this one, or use installMethod: 'script'." >&2
            exit 1
        fi
        if [[ "$VERSION" == "latest" || -z "$VERSION" ]]; then
            npm install -g opencode-ai
        else
            npm install -g opencode-ai@"${VERSION}"
        fi
        # Copy binary to /usr/local/bin for system-wide access
        OPENCODE_BIN="$(command -v opencode || true)"
        if [[ -z "$OPENCODE_BIN" ]]; then
            NPM_GLOBAL_BIN="$(npm bin -g 2>/dev/null || npm config get prefix 2>/dev/null)/bin"
            OPENCODE_BIN="$NPM_GLOBAL_BIN/opencode"
        fi
        if [[ ! -x "$OPENCODE_BIN" ]]; then
            echo "OpenCode installation failed: binary not found at $OPENCODE_BIN" >&2
            exit 1
        fi
        cp "$OPENCODE_BIN" /usr/local/bin/opencode
        chmod +x /usr/local/bin/opencode
        echo "OpenCode copied to /usr/local/bin/opencode"
        ;;

    script)
        curl -fsSL https://opencode.ai/install.sh -o /tmp/opencode-install.sh && bash /tmp/opencode-install.sh && rm -f /tmp/opencode-install.sh
        # Ensure binary is available system-wide
        OPENCODE_BIN="$(command -v opencode || true)"
        if [[ -z "$OPENCODE_BIN" ]]; then
            OPENCODE_BIN="$HOME/.local/bin/opencode"
        fi
        if [[ -x "$OPENCODE_BIN" ]] && [[ "$(readlink -f "$OPENCODE_BIN")" != "/usr/local/bin/opencode" ]]; then
            cp "$OPENCODE_BIN" /usr/local/bin/opencode
            chmod +x /usr/local/bin/opencode
        fi
        echo "OpenCode copied to /usr/local/bin/opencode"
        ;;

    *)
        echo "Error: unknown INSTALLMETHOD '${INSTALL_METHOD}'" >&2
        exit 1
        ;;
esac

if [[ ! -x /usr/local/bin/opencode ]]; then
    echo "OpenCode installation failed: /usr/local/bin/opencode not found" >&2
    exit 1
fi

# Shared agent config
mkdir -p "$AGENT_DIR"
if id -u "$REMOTE_USER" >/dev/null 2>&1; then
    chown -R "$REMOTE_USER:" "$AGENT_DIR"
fi

if [ -d "$REMOTE_USER_HOME" ]; then
    for target in "$REMOTE_USER_HOME/.opencode" "$REMOTE_USER_HOME/.config/opencode"; do
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
if command -v opencode >/dev/null 2>&1; then
    OUT=$(opencode --version 2>&1)
    RC=$?
    if [[ $RC -eq 0 ]]; then
        echo "OpenCode version: ${OUT}"
    else
        echo "OpenCode: version check skipped (exit ${RC})"
    fi
else
    echo "OpenCode: binary not on PATH; skipping version check"
fi
set -e

echo "OpenCode AI installed successfully!"
