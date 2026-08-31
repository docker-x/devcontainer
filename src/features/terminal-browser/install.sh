#!/bin/bash
set -e

# Terminal Browser Feature — install script
# Installs terminal-browser (https://github.com/zenbu-labs/terminal-browser),
# a real Chromium-based browser that renders inside the terminal via the
# kitty graphics protocol. Installs Electron/Chromium system dependencies
# via apt, then runs the official installer as the remote user.

REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-root}}"
REMOTE_USER_HOME="${_REMOTE_USER_HOME:-$(getent passwd "$REMOTE_USER" 2>/dev/null | cut -d: -f6)}"
REMOTE_USER_HOME="${REMOTE_USER_HOME:-/home/vscode}"

echo "terminal-browser: installing system dependencies for Electron/Chromium..."

# Consolidated apt call (per repo convention: one update, one install, one cleanup).
apt-get update -y
apt-get install -y --no-install-recommends \
    libnss3 \
    libatk1.0-0t64 \
    libatk-bridge2.0-0t64 \
    libcups2t64 \
    libdrm2 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libgtk-3-0t64 \
    libasound2t64 \
    libxshmfence1 \
    libx11-xcb1 \
    libxcb-dri3-0 \
    libpango-1.0-0 \
    libcairo2 \
    fonts-liberation
rm -rf /var/lib/apt/lists/*

echo "terminal-browser: running official installer as ${REMOTE_USER}..."

# The official installer downloads a tarball, verifies SHA-256, extracts to
# ~/.local/share/terminal-browser/app, and creates a wrapper in ~/.local/bin.
# It uses $HOME to determine install location — set it to the PVC-backed home.
export HOME="${REMOTE_USER_HOME}"

INSTALL_CMD='curl --proto =https -fsSL https://terminal-browser.sh/install | TERMINAL_BROWSER_SKIP_SETUP=1 bash'

if [[ "$REMOTE_USER" == "root" ]]; then
    sh -c "$INSTALL_CMD"
else
    su -s /bin/bash - "$REMOTE_USER" -c "$INSTALL_CMD"
fi

# Expose terminal-browser globally on PATH for all users.
TB_BIN="${REMOTE_USER_HOME}/.local/bin/terminal-browser"
if [[ -x "$TB_BIN" ]]; then
    ln -sf "$TB_BIN" /usr/local/bin/terminal-browser
else
    echo "Error: terminal-browser binary not found at $TB_BIN" >&2
    exit 1
fi

# Ensure ~/.local/bin is on PATH for login and non-login shells.
cat > /etc/profile.d/terminal-browser.sh <<EOF
export PATH="\${HOME}/.local/bin:\$PATH"
EOF
chmod 0755 /etc/profile.d/terminal-browser.sh

# Group-writable home .local dirs so random-UID containers (OpenShift SCC) can access.
if id -u "$REMOTE_USER" >/dev/null 2>&1; then
    chgrp -R 0 "$REMOTE_USER_HOME/.local" 2>/dev/null || true
    find "$REMOTE_USER_HOME/.local" -type d -exec chmod g+rwX {} + 2>/dev/null || true
fi

echo "terminal-browser: installed successfully!"
echo "  binary: $(readlink -f /usr/local/bin/terminal-browser)"
echo "  app:    ${REMOTE_USER_HOME}/.local/share/terminal-browser/app"
echo "Run 'terminal-browser' to launch, 'terminal-browser open <url>' to open a URL."
