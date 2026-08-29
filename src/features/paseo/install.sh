#!/bin/bash
set -e

VERSION=${VERSION:-"latest"}

echo "Installing Paseo CLI (version: ${VERSION})..."

# Ensure npm is available
if ! command -v npm &> /dev/null; then
    echo "Error: npm is required. Please install Node.js first." >&2
    exit 1
fi

# Install Paseo CLI globally
if [[ "$VERSION" == "latest" ]]; then
    npm install -g @getpaseo/cli
else
    npm install -g @getpaseo/cli@"$VERSION"
fi

# Verify installation
if command -v paseo &> /dev/null; then
    echo "Paseo CLI installed: $(paseo --version 2>&1 || echo 'version check skipped')"
else
    echo "Error: paseo not found on PATH after installation" >&2
    exit 1
fi

# Create .paseo directory in user home if it doesn't exist
REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-root}}"
REMOTE_USER_HOME="${_REMOTE_USER_HOME:-$(getent passwd "$REMOTE_USER" 2>/dev/null | cut -d: -f6)}"
REMOTE_USER_HOME="${REMOTE_USER_HOME:-/home/vscode}"

# Create .paseo directory and set PASEO_HOME to the PVC-backed path
mkdir -p "${REMOTE_USER_HOME}/.paseo"

echo "export PASEO_HOME=${REMOTE_USER_HOME}/.paseo" > /etc/profile.d/paseo-home.sh
chmod 0644 /etc/profile.d/paseo-home.sh
if grep -q 'PASEO_HOME=' /etc/environment 2>/dev/null; then
    sed -i "s|PASEO_HOME=.*|PASEO_HOME=${REMOTE_USER_HOME}/.paseo|" /etc/environment
else
    echo "PASEO_HOME=${REMOTE_USER_HOME}/.paseo" >> /etc/environment
fi

echo "Paseo CLI installed successfully!"

# Permission fix: only fix permissions on paseo-specific dirs, not all of /home/vscode
echo "Paseo: fixing permissions for OpenShift compatibility"
for dir in "${REMOTE_USER_HOME}/.paseo" "${REMOTE_USER_HOME}/.config/environment.d" "${REMOTE_USER_HOME}/.agents"; do
  if [[ -d "$dir" ]]; then
    chgrp -R 0 "$dir" 2>/dev/null || true
    chmod -R g+rwX "$dir" 2>/dev/null || true
  fi
done
# Make /home/vscode itself group-traversable but not group-writable
chgrp 0 "${REMOTE_USER_HOME}" 2>/dev/null || true
chmod 2755 "${REMOTE_USER_HOME}" 2>/dev/null || true

# Create a runtime-writable bin dir instead of making /usr/local/bin group-writable
RUNTIME_BIN="/usr/local/share/runtime-bin"
mkdir -p "$RUNTIME_BIN"
chgrp 0 "$RUNTIME_BIN" 2>/dev/null || true
chmod g+w "$RUNTIME_BIN" 2>/dev/null || true
# Add to PATH via profile.d
echo 'export PATH="$PATH:/usr/local/share/runtime-bin"' > /etc/profile.d/runtime-bin.sh
chmod 0644 /etc/profile.d/runtime-bin.sh

# Fix /usr/local/share/agent-config so runtime UID can write to config dirs
# (devin, claude, codex, opencode, kilo, gascity, herdr symlinks point here)
chgrp -R 0 /usr/local/share/agent-config 2>/dev/null || true
chmod -R g+rwX /usr/local/share/agent-config 2>/dev/null || true

# Defer permission fix to runtime via profile.d, so it catches dirs created by later features
cat > /etc/profile.d/paseo-perms.sh << 'PERMEOF'
# Fix permissions on agent-config dirs at shell startup (catches dirs created after paseo install)
for dir in "$HOME/.paseo" "$HOME/.agents" "$HOME/.config/environment.d"; do
  if [[ -d "$dir" ]]; then
    chgrp -R 0 "$dir" 2>/dev/null || true
    chmod -R g+rwX "$dir" 2>/dev/null || true
  fi
done
PERMEOF
chmod 0644 /etc/profile.d/paseo-perms.sh
