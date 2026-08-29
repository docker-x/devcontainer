#!/bin/bash
set -e

# DevPod Agent Feature — install script (LEGACY)
# DevPod is unmaintained. This feature exists only for rollback during
# the DevPod→Devsy migration. Do not use in new containers.

DEVPOD_VERSION="${VERSION:-v0.6.15}"

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

mkdir -p /home/vscode/.local/bin

# Pinned release tag — avoids mutable releases/latest URL (CWE-494).
DEVPOD_URL="https://github.com/loft-sh/devpod/releases/download/${DEVPOD_VERSION}/DevPod_linux_x86_64.tar.gz"
# SHA-256 of the v0.6.15 release artifact (CWE-494: integrity verification).
DEVPOD_SHA256="6c5bd63326f92a45707604970d70f6a8cc2c5ffffe703e0903a0c3ded4c042ab"

# Download to mktemp-allocated files (CWE-377: avoid predictable /tmp paths).
# --proto =https blocks HTTP redirect hijacking.
DEVPOD_TGZ="$(mktemp)"
DEVPOD_EXTRACT_DIR="$(mktemp -d)"
trap 'rm -f "$DEVPOD_TGZ"; rm -rf "$DEVPOD_EXTRACT_DIR"' EXIT

curl -fsSL --proto =https "$DEVPOD_URL" -o "$DEVPOD_TGZ"
printf '%s  %s\n' "$DEVPOD_SHA256" "$DEVPOD_TGZ" | sha256sum -c -

tar -xzf "$DEVPOD_TGZ" -C "$DEVPOD_EXTRACT_DIR" devpod 2>/dev/null || tar -xzf "$DEVPOD_TGZ" -C "$DEVPOD_EXTRACT_DIR" 2>/dev/null || true
if [ -f "$DEVPOD_EXTRACT_DIR/devpod" ]; then
  install -m 755 "$DEVPOD_EXTRACT_DIR/devpod" /home/vscode/.local/bin/devpod
elif [ -f "$DEVPOD_EXTRACT_DIR/devpod-linux-amd64" ]; then
  install -m 755 "$DEVPOD_EXTRACT_DIR/devpod-linux-amd64" /home/vscode/.local/bin/devpod
fi

# Group permissions for home directory data dirs, but keep binary non-group-writable
chgrp -R 0 /home/vscode/.local 2>/dev/null || true
find /home/vscode/.local -type d -exec chmod g+rwX {} + 2>/dev/null || true

echo "devpod: agent installed to /home/vscode/.local/bin/devpod"
