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
if [ "$VERSION" = "latest" ]; then
    npm install -g @getpaseo/cli
else
    npm install -g @getpaseo/cli@"$VERSION"
fi

# Verify installation
if command -v paseo &> /dev/null; then
    echo "Paseo CLI installed: $(paseo --version 2>&1 || echo 'version check skipped')"
else
    echo "Warning: paseo not found on PATH after installation" >&2
fi

# Create .paseo directory in user home if it doesn't exist
# NOTE: Do NOT create ~/.paseo as a real directory. The openshift-compat
# entrypoint will symlink it to /workspace-state/.paseo (PVC) at runtime.
# Creating it here as a real dir would prevent the symlink from working.
REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-root}}"
REMOTE_USER_HOME="${_REMOTE_USER_HOME:-$(getent passwd "$REMOTE_USER" 2>/dev/null | cut -d: -f6)}"

# Set up PASEO_HOME in /etc/profile.d so CLI and daemon share state
echo 'export PASEO_HOME=/workspace-state/.paseo' > /etc/profile.d/paseo-home.sh
chmod 0644 /etc/profile.d/paseo-home.sh
grep -q PASEO_HOME /etc/environment 2>/dev/null || echo 'PASEO_HOME=/workspace-state/.paseo' >> /etc/environment

echo "Paseo CLI installed successfully!"

# Final permission fix: ensure /home/vscode is group-writable by group 0
# for OpenShift random UID compatibility. Other features create files as
# UID 1000:GID 1000; this fixes them so the runtime UID (in group 0) can access.
echo "Paseo: fixing /home/vscode permissions for OpenShift compatibility"
chgrp -R 0 /home/vscode 2>/dev/null || true
chmod -R g+rwX /home/vscode 2>/dev/null || true
chmod 2775 /home/vscode 2>/dev/null || true

# Also fix /usr/local/bin so runtime entrypoint can create symlinks
chgrp 0 /usr/local/bin 2>/dev/null || true
chmod g+w /usr/local/bin 2>/dev/null || true

# Fix /etc/profile.d so runtime entrypoint can write profile scripts
chgrp 0 /etc/profile.d 2>/dev/null || true
chmod g+w /etc/profile.d 2>/dev/null || true
