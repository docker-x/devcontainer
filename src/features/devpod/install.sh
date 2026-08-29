#!/bin/bash
set -e

# DevPod Agent Feature — install script (LEGACY)
# DevPod is unmaintained. This feature exists only for rollback during
# the DevPod→Devsy migration. Do not use in new containers.

DEVPOD_VERSION="v0.6.15"

echo "devpod: pre-installing DevPod agent binary ${DEVPOD_VERSION} (legacy)"

# --- Install curl and tar if not present ---
APT_PKGS=""
command -v curl >/dev/null 2>&1 || APT_PKGS="curl"
command -v tar >/dev/null 2>&1 || APT_PKGS="$APT_PKGS tar"
APT_PKGS="${APT_PKGS# }"
if [ -n "$APT_PKGS" ]; then
  # shellcheck disable=SC2086
  apt-get update -y && apt-get install -y $APT_PKGS && rm -rf /var/lib/apt/lists/*
fi

REMOTE_USER_HOME="${_REMOTE_USER_HOME:-/home/vscode}"
mkdir -p "$REMOTE_USER_HOME/.local/bin"
mkdir -p /etc/skel/.local/bin

# Architecture detection — amd64 uses tar.gz, arm64 uses raw binary.
DEVPOD_ARCH="$(uname -m)"
case "$DEVPOD_ARCH" in
  x86_64)
    DEVPOD_ASSET="DevPod_linux_x86_64.tar.gz"
    DEVPOD_SHA256="6c5bd63326f92a45707604970d70f6a8cc2c5ffffe703e0903a0c3ded4c042ab"
    DEVPOD_IS_TARGZ=1
    ;;
  aarch64|arm64)
    DEVPOD_ASSET="devpod-linux-arm64"
    DEVPOD_SHA256="9226161e0c9f5a45d0f8d1778f940498e787b650f0e0fcf3c29f1f67e7a3f272"
    DEVPOD_IS_TARGZ=0
    ;;
  *)
    echo "devpod: unsupported architecture $DEVPOD_ARCH" >&2
    exit 1
    ;;
esac

# Pinned release tag — avoids mutable releases/latest URL (CWE-494).
DEVPOD_URL="https://github.com/loft-sh/devpod/releases/download/${DEVPOD_VERSION}/${DEVPOD_ASSET}"

# Download to mktemp-allocated files (CWE-377: avoid predictable /tmp paths).
# --proto =https blocks HTTP redirect hijacking.
DEVPOD_TMP="$(mktemp)"
DEVPOD_EXTRACT_DIR="$(mktemp -d)"
trap 'rm -f "$DEVPOD_TMP"; rm -rf "$DEVPOD_EXTRACT_DIR"' EXIT

curl -fsSL --proto =https "$DEVPOD_URL" -o "$DEVPOD_TMP"
printf '%s  %s\n' "$DEVPOD_SHA256" "$DEVPOD_TMP" | sha256sum -c -

if [ "$DEVPOD_IS_TARGZ" = "1" ]; then
  tar -xzf "$DEVPOD_TMP" -C "$DEVPOD_EXTRACT_DIR"
  # The tar.gz contains the CLI at usr/bin/devpod-cli (not a root-level binary).
  if [ -f "$DEVPOD_EXTRACT_DIR/usr/bin/devpod-cli" ]; then
    install -m 755 "$DEVPOD_EXTRACT_DIR/usr/bin/devpod-cli" /usr/local/bin/devpod
    install -m 755 "$DEVPOD_EXTRACT_DIR/usr/bin/devpod-cli" "$REMOTE_USER_HOME/.local/bin/devpod"
    install -m 755 "$DEVPOD_EXTRACT_DIR/usr/bin/devpod-cli" /etc/skel/.local/bin/devpod
  else
    echo "devpod: binary not found in archive after extraction" >&2
    exit 1
  fi
else
  install -m 755 "$DEVPOD_TMP" /usr/local/bin/devpod
  install -m 755 "$DEVPOD_TMP" "$REMOTE_USER_HOME/.local/bin/devpod"
  install -m 755 "$DEVPOD_TMP" /etc/skel/.local/bin/devpod
fi

# Group permissions for home directory data dirs, but keep binary non-group-writable
chgrp -R 0 "$REMOTE_USER_HOME/.local" 2>/dev/null || true
find "$REMOTE_USER_HOME/.local" -type d -exec chmod g+rwX {} + 2>/dev/null || true
chgrp -R 0 /etc/skel/.local 2>/dev/null || true
find /etc/skel/.local -type d -exec chmod g+rwX {} + 2>/dev/null || true

echo "devpod: agent installed to /usr/local/bin/devpod, $REMOTE_USER_HOME/.local/bin/devpod, /etc/skel/.local/bin/devpod"
