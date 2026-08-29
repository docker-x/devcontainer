#!/bin/bash
set -e

# Workspace Agent Feature — install script
# Pre-installs Devsy or DevPod agent binaries at build time.
# Used as a fallback when native agent injection fails (e.g. OpenShift
# restricted SCC blocks the injected agent process from running).

INSTALL_DEVSY_AGENT="${INSTALLDEVSYAGENT:-false}"
INSTALL_DEVPOD_AGENT="${INSTALLDEVPODAGENT:-false}"
DEVSY_VERSION="${DEVSYVERSION:-v1.16.2}"

echo "workspace-agent: devsy=${INSTALL_DEVSY_AGENT} (v${DEVSY_VERSION}), devpod=${INSTALL_DEVPOD_AGENT}"

# --- Pre-install Devsy agent binary ---
if [[ "$INSTALL_DEVSY_AGENT" == "true" ]]; then
  echo "workspace-agent: pre-installing Devsy agent binary ${DEVSY_VERSION}"
  if ! command -v curl >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
  fi
  # Select architecture-appropriate release asset (reject unsupported archs)
  DEVSY_ARCH="$(uname -m)"
  case "$DEVSY_ARCH" in
    x86_64) DEVSY_ASSET="devsy-linux-amd64" ;;
    aarch64|arm64) DEVSY_ASSET="devsy-linux-arm64" ;;
    *) echo "workspace-agent: unsupported architecture $DEVSY_ARCH for Devsy agent" >&2; exit 1 ;;
  esac
  # Pinned release tag — avoids mutable releases/latest URL (CWE-494).
  DEVSY_URL="https://github.com/devsy-org/devsy/releases/download/${DEVSY_VERSION}/${DEVSY_ASSET}"
  # Download once to a mktemp-allocated file (CWE-377: avoid predictable /tmp path).
  # --proto =https blocks HTTP redirect hijacking.
  DEVSY_TMP="$(mktemp)"
  trap 'rm -f "$DEVSY_TMP"' EXIT
  curl -fsSL --proto =https "$DEVSY_URL" -o "$DEVSY_TMP"
  # /usr/local/bin — always on PATH, not hidden by PVC home mounts
  install -m 755 "$DEVSY_TMP" /usr/local/bin/devsy
  # /home/vscode/.local/bin — home-based PATH (may be hidden by PVC)
  mkdir -p /home/vscode/.local/bin
  install -m 755 "$DEVSY_TMP" /home/vscode/.local/bin/devsy
  # /etc/skel/.local/bin — repopulated into home on first PVC boot by entrypoint
  mkdir -p /etc/skel/.local/bin
  install -m 755 "$DEVSY_TMP" /etc/skel/.local/bin/devsy
  rm -f "$DEVSY_TMP"
  # Group permissions for home directory data dirs, but keep binary non-group-writable
  chgrp -R 0 /home/vscode/.local 2>/dev/null || true
  find /home/vscode/.local -type d -exec chmod g+rwX {} + 2>/dev/null || true
  chmod 755 /home/vscode/.local/bin/devsy 2>/dev/null || true
  echo "workspace-agent: Devsy agent installed to /usr/local/bin/devsy, /home/vscode/.local/bin/devsy, /etc/skel/.local/bin/devsy"
fi

# --- Pre-install DevPod agent binary (legacy, kept for rollback) ---
if [[ "$INSTALL_DEVPOD_AGENT" == "true" ]]; then
  echo "workspace-agent: pre-installing DevPod agent binary (legacy)"
  if ! command -v curl >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y curl tar && rm -rf /var/lib/apt/lists/*
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
  echo "workspace-agent: DevPod agent installed to /home/vscode/.local/bin/devpod"
fi

# Re-assert non-group-writable mode on the Devsy binary after the DevPod block,
# whose recursive chmod may have flipped it from 755 to 775.
if [[ "$INSTALL_DEVSY_AGENT" == "true" ]] && [[ -f /home/vscode/.local/bin/devsy ]]; then
  chmod 755 /home/vscode/.local/bin/devsy 2>/dev/null || true
fi

echo "workspace-agent: installation complete"
