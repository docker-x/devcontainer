#!/bin/bash
set -e

# Bun JavaScript Runtime Installation Script

VERSION="${VERSION:-"latest"}"
REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-root}}"
REMOTE_USER_HOME="${_REMOTE_USER_HOME:-$(getent passwd "$REMOTE_USER" 2>/dev/null | cut -d: -f6)}"
REMOTE_USER_HOME="${REMOTE_USER_HOME:-/home/vscode}"
AGENT_DIR="${AGENT_CONFIG_DIR:-/usr/local/share/agent-config}/bun"

echo "Installing Bun JavaScript runtime ${VERSION}..."

# The official Bun installer uses $HOME to determine the install location.
# Ensure HOME is set so bun lands in the remote user's home directory.
export HOME="${REMOTE_USER_HOME}"
BUN_INSTALL_DIR="${HOME}/.bun"

# Run the official Bun installer as the remote user so files are owned correctly.
INSTALL_CMD="curl --proto =https -fsSL https://bun.sh/install | HOME='$HOME' bash"
if [[ "$VERSION" != "latest" ]]; then
    INSTALL_CMD="curl --proto =https -fsSL https://bun.sh/install | HOME='$HOME' bash -s '$VERSION'"
fi

if [[ "$REMOTE_USER" == "root" ]]; then
    sh -c "$INSTALL_CMD"
else
    su -s /bin/bash - "$REMOTE_USER" -c "$INSTALL_CMD"
fi

# Expose bun binary globally on PATH for all users.
if [ -x "$BUN_INSTALL_DIR/bin/bun" ]; then
    ln -sf "$BUN_INSTALL_DIR/bin/bun" /usr/local/bin/bun
else
    echo "Error: Bun binary not found at $BUN_INSTALL_DIR/bin/bun" >&2
    exit 1
fi

# Set up BUN_INSTALL environment variable for all users.
cat > /etc/profile.d/bun.sh <<EOF
export BUN_INSTALL="$BUN_INSTALL_DIR"
export PATH="\$BUN_INSTALL/bin:\$PATH"
EOF
chmod 0755 /etc/profile.d/bun.sh

# Persist BUN_INSTALL in /etc/environment for non-login shells.
grep -q "^BUN_INSTALL=" /etc/environment 2>/dev/null || \
    echo "BUN_INSTALL=\"$BUN_INSTALL_DIR\"" >> /etc/environment

# Shared agent config for Bun.
mkdir -p "$AGENT_DIR"
if id -u "$REMOTE_USER" >/dev/null 2>&1; then
    chown -R "$REMOTE_USER:" "$AGENT_DIR"
fi

if [ -d "$REMOTE_USER_HOME" ]; then
    target="$REMOTE_USER_HOME/.config/bun"
    if [ -e "$target" ] && [ ! -L "$target" ]; then
        mv "$target" "$AGENT_DIR/config-legacy"
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
fi

echo "Bun configured to use $AGENT_DIR"
echo "Bun installed successfully!"
/usr/local/bin/bun --version
