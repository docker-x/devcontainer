#!/bin/bash
set -e

# DevPod Agent Feature — install script (LEGACY)
# DevPod is unmaintained. This feature exists only for rollback during
# the DevPod→Devsy migration. Do not use in new containers.

echo "devpod: pre-installing DevPod agent binary (legacy)"

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
DEVPOD_URL="https://github.com/loft-sh/devpod/releases/latest/download/devpod_Linux_x86_64.tar.gz"
curl -fsSL --proto =https "$DEVPOD_URL" -o /tmp/devpod.tar.gz
tar -xzf /tmp/devpod.tar.gz -C /tmp devpod 2>/dev/null || tar -xzf /tmp/devpod.tar.gz -C /tmp 2>/dev/null || true
if [ -f /tmp/devpod ]; then
  install -m 755 /tmp/devpod /home/vscode/.local/bin/devpod
elif [ -f /tmp/devpod-linux-amd64 ]; then
  install -m 755 /tmp/devpod-linux-amd64 /home/vscode/.local/bin/devpod
fi
rm -f /tmp/devpod.tar.gz

chgrp -R 0 /home/vscode/.local 2>/dev/null || true
find /home/vscode/.local -type d -exec chmod g+rwX {} + 2>/dev/null || true
chmod 755 /home/vscode/.local/bin/devpod 2>/dev/null || true

echo "devpod: agent installed to /home/vscode/.local/bin/devpod"
