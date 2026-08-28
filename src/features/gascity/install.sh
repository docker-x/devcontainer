#!/bin/bash
set -e

# Gas City Installation Script

REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-root}}"
REMOTE_USER_HOME="${_REMOTE_USER_HOME:-$(getent passwd "$REMOTE_USER" 2>/dev/null | cut -d: -f6)}"
AGENT_DIR="${AGENT_CONFIG_DIR:-/usr/local/share/agent-config}/gascity"
HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"

echo "Installing Gas City for user $REMOTE_USER..."

export PATH="$HOMEBREW_PREFIX/bin:$PATH"

# Ensure Homebrew is present
if ! command -v brew &> /dev/null; then
    echo "Error: Homebrew not found. The homebrew feature must be installed first." >&2
    exit 1
fi

# Install Gas City if it is not already available
if ! command -v gc &> /dev/null; then
    echo "Gas City not found; installing via Homebrew..."
    su -s /bin/bash - "$REMOTE_USER" -c \
        "export PATH='$HOMEBREW_PREFIX/bin:\$PATH'; brew install gastownhall/gascity/gascity"
fi

export PATH="$HOMEBREW_PREFIX/bin:$PATH"
echo "gc found at: $(which gc 2>/dev/null || echo "$HOMEBREW_PREFIX/bin/gc")"
gc version || true

# Expose key binaries globally
if [ -f "$HOMEBREW_PREFIX/bin/gc" ]; then
    ln -sf "$HOMEBREW_PREFIX/bin/gc" /usr/local/bin/gc
fi
if [ -f "$HOMEBREW_PREFIX/bin/dolt" ]; then
    ln -sf "$HOMEBREW_PREFIX/bin/dolt" /usr/local/bin/dolt
fi

BD_BIN=$(find /home/linuxbrew/.linuxbrew/Cellar/beads -name bd -type f 2>/dev/null | head -n1 || true)
if [ -n "$BD_BIN" ]; then
    ln -sf "$BD_BIN" /usr/local/bin/bd
fi

if [ -f "$HOMEBREW_PREFIX/bin/tmux" ]; then
    ln -sf "$HOMEBREW_PREFIX/bin/tmux" /usr/local/bin/tmux
fi

# Shared agent config for Gas City
mkdir -p "$AGENT_DIR"
if id -u "$REMOTE_USER" >/dev/null 2>&1; then
    chown -R "$REMOTE_USER:" "$AGENT_DIR"
fi

if [ -d "$REMOTE_USER_HOME" ]; then
    if [ -e "$REMOTE_USER_HOME/.gascity" ] && [ ! -L "$REMOTE_USER_HOME/.gascity" ]; then
        mv "$REMOTE_USER_HOME/.gascity" "$AGENT_DIR/legacy-gascity"
    fi
    rm -f "$REMOTE_USER_HOME/.gascity"
    su -s /bin/bash - "$REMOTE_USER" -c "ln -sfn '$AGENT_DIR' '$REMOTE_USER_HOME/.gascity'" 2>/dev/null || true
fi

# Entrypoint for container startup
mkdir -p /usr/local/share/gascity
cp scripts/entrypoint.sh /usr/local/share/gascity/entrypoint.sh
chmod +x /usr/local/share/gascity/entrypoint.sh

AUTOREGISTER="${AUTOREGISTER:-false}"
if [ "$AUTOREGISTER" = "true" ]; then
    echo "true" > /usr/local/share/gascity/autoregister_enabled
else
    echo "false" > /usr/local/share/gascity/autoregister_enabled
fi
chmod 644 /usr/local/share/gascity/autoregister_enabled

echo "Gas City installed successfully!"
