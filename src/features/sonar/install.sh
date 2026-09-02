#!/bin/bash
set -e

# SonarScanner CLI Installation Script
# Downloads from binaries.sonarsource.com, verifies SHA-256 against the
# publisher's per-asset .sha256 file, and installs to /opt with symlinks
# in /usr/local/bin.

SONAR_VERSION="${VERSION:-8.1.0.6389}"
INCLUDE_JRE="${INCLUDEJRE:-true}"

# Resolve remote user home (OpenShift restricted SCC can set HOME=/).
REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-root}}"
REMOTE_USER_HOME="${_REMOTE_USER_HOME:-$(getent passwd "$REMOTE_USER" 2>/dev/null | cut -d: -f6)}"
REMOTE_USER_HOME="${REMOTE_USER_HOME:-/home/vscode}"

echo "Installing SonarScanner CLI ${SONAR_VERSION} (includeJre: ${INCLUDE_JRE})..."

# --- Ensure curl + unzip + CA bundle are present ---
if ! command -v curl >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1 || [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
    apt-get update -y
    apt-get install -y curl ca-certificates unzip
    rm -rf /var/lib/apt/lists/*
fi

# --- Determine download URL and extracted directory name ---
SONAR_BASE="https://binaries.sonarsource.com/Distribution/sonar-scanner-cli"

if [[ "$INCLUDE_JRE" == "true" ]]; then
    SONAR_ARCH="$(uname -m)"
    case "$SONAR_ARCH" in
        x86_64)  SONAR_ARCH="x64" ;;
        aarch64|arm64) SONAR_ARCH="aarch64" ;;
        *) echo "Error: unsupported architecture $(uname -m) for JRE bundle" >&2; exit 1 ;;
    esac
    SONAR_ZIP="sonar-scanner-cli-${SONAR_VERSION}-linux-${SONAR_ARCH}.zip"
    SONAR_DIR="sonar-scanner-${SONAR_VERSION}-linux-${SONAR_ARCH}"
else
    SONAR_ZIP="sonar-scanner-cli-${SONAR_VERSION}.zip"
    SONAR_DIR="sonar-scanner-${SONAR_VERSION}"
fi

SONAR_ZIP_URL="${SONAR_BASE}/${SONAR_ZIP}"
SONAR_SHA_URL="${SONAR_BASE}/${SONAR_ZIP}.sha256"

# --- Download to a mktemp directory (CWE-377) ---
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# --- Download the .sha256 file (CWE-494: integrity verification) ---
echo "Downloading checksum: ${SONAR_SHA_URL}"
curl -fsSL --proto =https --proto-redir =https "$SONAR_SHA_URL" -o "${WORK_DIR}/checksum.sha256"

# --- Download the zip ---
echo "Downloading: ${SONAR_ZIP_URL}"
curl -fsSL --proto =https --proto-redir =https "$SONAR_ZIP_URL" -o "${WORK_DIR}/${SONAR_ZIP}"

# --- Verify SHA-256 ---
# The .sha256 file contains just the hash (no filename).
EXPECTED_SHA=$(awk '{print $1}' "${WORK_DIR}/checksum.sha256")
if [[ -z "$EXPECTED_SHA" ]]; then
    echo "Error: could not read SHA-256 from ${SONAR_SHA_URL}" >&2
    exit 1
fi
ACTUAL_SHA=$(sha256sum "${WORK_DIR}/${SONAR_ZIP}" | awk '{print $1}')
if [[ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
    echo "Error: SHA-256 mismatch for ${SONAR_ZIP}" >&2
    echo "  expected: ${EXPECTED_SHA}" >&2
    echo "  actual:   ${ACTUAL_SHA}" >&2
    exit 1
fi
echo "SHA-256 verified: ${ACTUAL_SHA}"

# --- Extract and install ---
unzip -q "${WORK_DIR}/${SONAR_ZIP}" -d /opt
SONAR_HOME="/opt/${SONAR_DIR}"
if [[ ! -d "$SONAR_HOME" ]]; then
    echo "Error: expected extracted directory ${SONAR_HOME} not found." >&2
    exit 1
fi

ln -sf "${SONAR_HOME}/bin/sonar-scanner" /usr/local/bin/sonar-scanner
ln -sf "${SONAR_HOME}/bin/sonar-scanner-debug" /usr/local/bin/sonar-scanner-debug

# --- Env exports ---
# Use REMOTE_USER_HOME for SONAR_USER_HOME, not $HOME — OpenShift restricted
# SCC sets HOME=/ which would write cache to /.sonar (ephemeral, not PVC-backed).
rm -f /etc/profile.d/sonar.sh
cat > /etc/profile.d/sonar.sh <<EOF
export SONAR_SCANNER_HOME="${SONAR_HOME}"
export SONAR_USER_HOME="${REMOTE_USER_HOME}/.sonar"
export PATH="${SONAR_HOME}/bin:\$PATH"
EOF
chmod 0755 /etc/profile.d/sonar.sh

# Persist env vars in /etc/environment for non-login shells.
grep -q "^SONAR_SCANNER_HOME=" /etc/environment 2>/dev/null || \
    echo "SONAR_SCANNER_HOME=\"${SONAR_HOME}\"" >> /etc/environment
grep -q "^SONAR_USER_HOME=" /etc/environment 2>/dev/null || \
    echo "SONAR_USER_HOME=\"${REMOTE_USER_HOME}/.sonar\"" >> /etc/environment

echo "SonarScanner CLI installed successfully!"
