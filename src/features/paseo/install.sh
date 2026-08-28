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
    npm install -g "@getpaseo/cli@$VERSION"
fi

# Verify installation
if command -v paseo &> /dev/null; then
    echo "Paseo CLI installed: $(paseo --version 2>&1 || echo 'version check skipped')"
else
    echo "Warning: paseo not found on PATH after installation" >&2
fi

# Create .paseo directory in user home if it doesn't exist
REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-root}}"
REMOTE_USER_HOME="${_REMOTE_USER_HOME:-$(getent passwd "$REMOTE_USER" 2>/dev/null | cut -d: -f6)}"
REMOTE_USER_HOME="${REMOTE_USER_HOME:-$(eval echo ~$REMOTE_USER)}"

if [ -n "$REMOTE_USER_HOME" ] && [ -d "$REMOTE_USER_HOME" ]; then
    mkdir -p "$REMOTE_USER_HOME/.paseo"
    if id -u "$REMOTE_USER" >/dev/null 2>&1; then
        chown -R "$REMOTE_USER:$REMOTE_USER" "$REMOTE_USER_HOME/.paseo"
    fi
fi

echo "Paseo CLI installed successfully!"
