#!/bin/bash
set -e

# Devsy Agent Feature — install script
# Pre-installs the Devsy agent binary at build time.
# Used as a fallback when native agent injection fails (e.g. OpenShift
# restricted SCC blocks the injected agent process from running).

DEVSY_VERSION="v1.16.2"

echo "devsy: pre-installing Devsy agent binary ${DEVSY_VERSION}"

# --- Install curl if not present ---
if ! command -v curl >/dev/null 2>&1; then
  apt-get update -y && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
fi

# Select architecture-appropriate release asset (reject unsupported archs)
DEVSY_ARCH="$(uname -m)"
case "$DEVSY_ARCH" in
  x86_64) DEVSY_ASSET="devsy-linux-amd64"; DEVSY_SHA256="4983c52a3536c5a91d1b5f356a1c3428778ebf3f896d9897f60bce3978abc839" ;;
  aarch64|arm64) DEVSY_ASSET="devsy-linux-arm64"; DEVSY_SHA256="31060b96486b5398f2aa3ee0875b2555782a2db0954a799d387be38ed4b4990d" ;;
  *) echo "devsy: unsupported architecture $DEVSY_ARCH" >&2; exit 1 ;;
esac

# Pinned release tag — avoids mutable releases/latest URL (CWE-494).
DEVSY_URL="https://github.com/devsy-org/devsy/releases/download/${DEVSY_VERSION}/${DEVSY_ASSET}"
# Download to a mktemp-allocated file (CWE-377: avoid predictable /tmp path).
# --proto =https blocks HTTP redirect hijacking.
DEVSY_TMP="$(mktemp)"
trap 'rm -f "$DEVSY_TMP"' EXIT
curl -fsSL --proto =https "$DEVSY_URL" -o "$DEVSY_TMP"
# Verify SHA-256 digest (CWE-494: integrity check for downloaded binary).
printf '%s  %s\n' "$DEVSY_SHA256" "$DEVSY_TMP" | sha256sum -c -

# Use _REMOTE_USER_HOME if available (set by common-utils feature), fallback to /home/vscode
REMOTE_USER_HOME="${_REMOTE_USER_HOME:-/home/vscode}"

# /usr/local/bin — always on PATH, not hidden by PVC home mounts
install -m 755 "$DEVSY_TMP" /usr/local/bin/devsy
# $REMOTE_USER_HOME/.local/bin — home-based PATH (may be hidden by PVC)
mkdir -p "$REMOTE_USER_HOME/.local/bin"
install -m 755 "$DEVSY_TMP" "$REMOTE_USER_HOME/.local/bin/devsy"
# /etc/skel/.local/bin — repopulated into home on first PVC boot by entrypoint
mkdir -p /etc/skel/.local/bin
install -m 755 "$DEVSY_TMP" /etc/skel/.local/bin/devsy

# Group permissions for home directory data dirs, but keep binary non-group-writable
chgrp -R 0 "$REMOTE_USER_HOME/.local" 2>/dev/null || true
find "$REMOTE_USER_HOME/.local" -type d -exec chmod g+rwX {} + 2>/dev/null || true

echo "devsy: agent installed to /usr/local/bin/devsy, $REMOTE_USER_HOME/.local/bin/devsy, /etc/skel/.local/bin/devsy"
