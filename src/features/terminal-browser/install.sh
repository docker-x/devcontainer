#!/bin/bash
set -e

# Terminal Browser Feature — install script
# Installs terminal-browser (https://github.com/zenbu-labs/terminal-browser),
# a real Chromium-based browser that renders inside the terminal via the
# kitty graphics protocol. Installs Electron/Chromium system dependencies
# via apt, then runs the official installer as the remote user.
#
# Requires Ubuntu 24.04+ (t64 package names match the 64-bit time_t transition).

REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-root}}"
REMOTE_USER_HOME="${_REMOTE_USER_HOME:-$(getent passwd "$REMOTE_USER" 2>/dev/null | cut -d: -f6)}"
REMOTE_USER_HOME="${REMOTE_USER_HOME:-/home/vscode}"

echo "terminal-browser: installing system dependencies for Electron/Chromium..."

# Consolidated apt call (per repo convention: one update, one install, one cleanup).
# Package names with t64 suffix are the correct names on Ubuntu 24.04 (64-bit time_t transition).
apt-get update -y
apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
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

echo "terminal-browser: downloading and verifying installer..."

# Download the installer to a temp file first (CWE-494: don't pipe curl to bash).
# The official installer itself verifies the tarball SHA-256 before extracting.
INSTALLER_TMP="$(mktemp)"
trap 'rm -f "$INSTALLER_TMP"' EXIT
curl --proto =https -fsSL https://terminal-browser.sh/install -o "$INSTALLER_TMP"
# mktemp creates files with mode 0600 owned by root — make world-readable
# so the su'd remote user can execute it (P0: non-root install path).
chmod a+r "$INSTALLER_TMP"

echo "terminal-browser: running installer as ${REMOTE_USER}..."

# The official installer downloads a tarball, verifies SHA-256, extracts to
# ~/.local/share/terminal-browser/app, and creates a wrapper in ~/.local/bin.
# Pre-create the .local directory tree and chown to the remote user — the
# installer runs as the remote user and can't create these if the home dir
# is root-owned (common in devcontainer base images).
mkdir -p "${REMOTE_USER_HOME}/.local/bin" "${REMOTE_USER_HOME}/.local/share"
# chown is best-effort — may fail on read-only or root-squashed mounts,
# but the dirs may already be usable by the remote user.
if id -u "$REMOTE_USER" >/dev/null 2>&1; then
    chown -R "$REMOTE_USER:" "${REMOTE_USER_HOME}/.local" 2>/dev/null || true
fi

# It uses $HOME to determine install location — set it to the PVC-backed home.
export HOME="${REMOTE_USER_HOME}"

# Run the downloaded installer (not a login shell — don't reset HOME).
# Escape home path for safe embedding in command strings (printf '%q' convention).
ESCAPED_HOME="$(printf '%q' "$REMOTE_USER_HOME")"
INSTALL_CMD="TERMINAL_BROWSER_SKIP_SETUP=1 bash '$INSTALLER_TMP'"

if [[ "$REMOTE_USER" == "root" ]]; then
    sh -c "$INSTALL_CMD"
else
    su -s /bin/bash "$REMOTE_USER" -c "export HOME=$ESCAPED_HOME; $INSTALL_CMD"
fi

# Create a root-owned wrapper in /usr/local/bin instead of symlinking into
# the group-writable user home (prevents another group-0 user from replacing it).
TB_APP="${REMOTE_USER_HOME}/.local/share/terminal-browser/app"
TB_HOME_BIN="${REMOTE_USER_HOME}/.local/bin/terminal-browser"
if [[ -x "$TB_HOME_BIN" ]]; then
    # Remove any existing file/symlink first — cat > follows symlinks,
    # which would create a self-recursive wrapper on rerun (P2).
    rm -f /usr/local/bin/terminal-browser
    cat > /usr/local/bin/terminal-browser <<EOF
#!/bin/sh
exec "$TB_HOME_BIN" "\$@"
EOF
    chmod 755 /usr/local/bin/terminal-browser
else
    echo "Error: terminal-browser binary not found at $TB_HOME_BIN" >&2
    exit 1
fi

# Ensure ~/.local/bin is on PATH for login and non-login shells.
# Hardcode REMOTE_USER_HOME instead of ${HOME} — OpenShift restricted SCC
# sets HOME=/ for random-UID containers, which would resolve to /.local/bin.
cat > /etc/profile.d/terminal-browser.sh <<EOF
export PATH="${REMOTE_USER_HOME}/.local/bin:\$PATH"
EOF
chmod 0755 /etc/profile.d/terminal-browser.sh

# Group-writable home .local dirs so random-UID containers (OpenShift SCC) can access.
# Don't suppress errors — if this fails, random-UID processes will get permission denied.
if id -u "$REMOTE_USER" >/dev/null 2>&1; then
    chgrp -R 0 "$REMOTE_USER_HOME/.local"
    find "$REMOTE_USER_HOME/.local" -type d -exec chmod g+rwX {} +
fi

echo "terminal-browser: installed successfully!"
echo "  wrapper: /usr/local/bin/terminal-browser"
echo "  app:     ${TB_APP}"
echo "Run 'terminal-browser' to launch, 'terminal-browser open <url>' to open a URL."
