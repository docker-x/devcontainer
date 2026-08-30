#!/bin/bash
set -e

# Kilo CLI installation script for Devcontainers.
# Installs the Kilo binary directly from GitHub releases.

VERSION="${VERSION:-latest}"
REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-root}}"
REMOTE_USER_HOME="${_REMOTE_USER_HOME:-$(getent passwd "$REMOTE_USER" 2>/dev/null | cut -d: -f6)}"
AGENT_DIR="${AGENT_CONFIG_DIR:-/usr/local/share/agent-config}/kilo"
INSTALL_DIR="/usr/local/bin"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Installing Kilo CLI ${VERSION}..."

# Install apt-level dependency for notifications
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y libnotify-bin
    rm -rf /var/lib/apt/lists/*
else
    echo "Warning: apt-get not available; skipping libnotify-bin install" >&2
fi

# Detect architecture: x86_64 -> x64, aarch64 -> arm64
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
    x86_64|amd64) ARCH="x64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)
        echo "Error: unsupported architecture '$ARCH_RAW' for Kilo" >&2
        exit 1
        ;;
esac

# Detect libc flavor for x64 (glibc vs musl). arm64 uses the glibc build.
LIBC_SUFFIX=""
if [ "$ARCH" = "x64" ]; then
    if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
        LIBC_SUFFIX="-musl"
    elif [ -f /etc/alpine-release ] || command -v apk >/dev/null 2>&1; then
        LIBC_SUFFIX="-musl"
    fi
fi

# Build the release download URL.
ASSET="kilo-linux-${ARCH}${LIBC_SUFFIX}.tar.gz"
if [ "$VERSION" = "latest" ]; then
    DOWNLOAD_URL="https://github.com/Kilo-Org/kilo/releases/latest/download/${ASSET}"
else
    # Strip a leading 'v' if present when building the tag path.
    VERSION_TAG="${VERSION#v}"
    DOWNLOAD_URL="https://github.com/Kilo-Org/kilo/releases/download/v${VERSION_TAG}/${ASSET}"
fi

echo "Downloading Kilo from $DOWNLOAD_URL ..."
TARBALL="$TMP_DIR/kilo.tar.gz"
if ! curl --proto =https -fsSL "$DOWNLOAD_URL" -o "$TARBALL"; then
    echo "Error: failed to download Kilo release asset '$ASSET'" >&2
    echo "       URL: $DOWNLOAD_URL" >&2
    exit 1
fi

# Extract the tarball and locate the kilo binary.
EXTRACT_DIR="$TMP_DIR/extract"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$TARBALL" -C "$EXTRACT_DIR"
KILO_BIN="$(find "$EXTRACT_DIR" -type f -name kilo -perm -u+x | head -n1)"
if [ -z "$KILO_BIN" ]; then
    # Fall back to any file named kilo and make it executable.
    KILO_BIN="$(find "$EXTRACT_DIR" -type f -name kilo | head -n1)"
fi
if [ -z "$KILO_BIN" ]; then
    echo "Error: could not find the 'kilo' binary inside the release tarball" >&2
    exit 1
fi

# Install the binary globally.
mkdir -p "$INSTALL_DIR"
cp "$KILO_BIN" "$INSTALL_DIR/kilo"
chmod +x "$INSTALL_DIR/kilo"

# Verify the installation (non-fatal).
if command -v kilo >/dev/null 2>&1; then
    echo "Kilo CLI installed successfully!"
    kilo --version 2>/dev/null || echo "Warning: 'kilo --version' failed; continuing" >&2
else
    echo "Warning: Kilo CLI installation completed but 'kilo' command not found in PATH" >&2
fi

# Shared agent config for Kilo
mkdir -p "$AGENT_DIR"
if id -u "$REMOTE_USER" >/dev/null 2>&1; then
    chown -R "$REMOTE_USER:" "$AGENT_DIR"
fi

if [ -d "$REMOTE_USER_HOME" ]; then
    for target in "$REMOTE_USER_HOME/.kilo" "$REMOTE_USER_HOME/.config/kilo"; do
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

echo "Kilo CLI configured to use $AGENT_DIR"
