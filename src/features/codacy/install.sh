#!/bin/bash
set -e

# Codacy CLI v2 Installation Script
# Downloads from GitHub releases, verifies SHA-256 against the publisher's
# checksums file, and installs the binary to /usr/local/bin.

VERSION="${VERSION:-latest}"

echo "Installing Codacy CLI v2 (version: ${VERSION})..."

# --- Ensure curl + jq + CA bundle are present ---
if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
    apt-get update -y
    apt-get install -y curl jq ca-certificates
    rm -rf /var/lib/apt/lists/*
fi

# --- Resolve version ---
if [[ "$VERSION" == "latest" ]]; then
    VERSION=$(curl -fsSL --proto =https --proto-redir =https https://api.github.com/repos/codacy/codacy-cli-v2/releases/latest | jq -r '.tag_name')
    if [[ -z "$VERSION" || "$VERSION" == "null" ]]; then
        echo "Error: could not determine latest Codacy CLI release tag." >&2
        exit 1
    fi
fi
echo "Codacy CLI version: ${VERSION}"

# --- Select architecture-appropriate release asset ---
CODACY_ARCH="$(uname -m)"
case "$CODACY_ARCH" in
    x86_64)  CODACY_ASSET="codacy-cli-v2_${VERSION}_linux_amd64.tar.gz" ;;
    aarch64|arm64) CODACY_ASSET="codacy-cli-v2_${VERSION}_linux_arm64.tar.gz" ;;
    *) echo "Error: unsupported architecture $CODACY_ARCH" >&2; exit 1 ;;
esac

# --- Download to a mktemp directory (CWE-377) ---
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

CODACY_BASE="https://github.com/codacy/codacy-cli-v2/releases/download/${VERSION}"
CODACY_ASSET_URL="${CODACY_BASE}/${CODACY_ASSET}"
CODACY_CHECKSUMS_URL="${CODACY_BASE}/codacy-cli-v2_${VERSION}_checksums.txt"

# --- Download checksums file (CWE-494: integrity verification) ---
echo "Downloading checksums: ${CODACY_CHECKSUMS_URL}"
curl -fsSL --proto =https --proto-redir =https "$CODACY_CHECKSUMS_URL" -o "${WORK_DIR}/checksums.txt"

# --- Download the release tarball ---
echo "Downloading: ${CODACY_ASSET_URL}"
curl -fsSL --proto =https --proto-redir =https "$CODACY_ASSET_URL" -o "${WORK_DIR}/${CODACY_ASSET}"

# --- Verify SHA-256 against the publisher's checksums file ---
EXPECTED_SHA=$(grep "  ${CODACY_ASSET}\$" "${WORK_DIR}/checksums.txt" | awk '{print $1}')
if [[ -z "$EXPECTED_SHA" ]]; then
    echo "Error: no checksum found for ${CODACY_ASSET} in checksums file." >&2
    exit 1
fi
ACTUAL_SHA=$(sha256sum "${WORK_DIR}/${CODACY_ASSET}" | awk '{print $1}')
if [[ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
    echo "Error: SHA-256 mismatch for ${CODACY_ASSET}" >&2
    echo "  expected: ${EXPECTED_SHA}" >&2
    echo "  actual:   ${ACTUAL_SHA}" >&2
    exit 1
fi
echo "SHA-256 verified: ${ACTUAL_SHA}"

# --- Extract and install ---
tar xzf "${WORK_DIR}/${CODACY_ASSET}" -C "${WORK_DIR}" codacy-cli-v2
install -m 755 "${WORK_DIR}/codacy-cli-v2" /usr/local/bin/codacy-cli-v2
ln -sf /usr/local/bin/codacy-cli-v2 /usr/local/bin/codacy-cli

# --- Env exports for non-login shells ---
# Shell-quote VERSION to prevent injection via user-controlled version option.
VERSION_ESCAPED=$(printf '%q' "$VERSION")
rm -f /etc/profile.d/codacy.sh
cat > /etc/profile.d/codacy.sh <<EOF
export CODACY_CLI_V2_VERSION=${VERSION_ESCAPED}
EOF
chmod 0755 /etc/profile.d/codacy.sh

# Persist in /etc/environment for non-login shells.
grep -q "^CODACY_CLI_V2_VERSION=" /etc/environment 2>/dev/null || \
    echo "CODACY_CLI_V2_VERSION=\"${VERSION}\"" >> /etc/environment

echo "Codacy CLI v2 installed successfully!"
