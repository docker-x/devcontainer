#!/bin/bash
set -e

# Devin CLI Installation Script (non-interactive)

VERSION=${VERSION:-"latest"}
INSTALL_METHOD=${INSTALLMETHOD:-"script"}

REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-root}}"
REMOTE_USER_HOME="${_REMOTE_USER_HOME:-$(getent passwd "$REMOTE_USER" 2>/dev/null | cut -d: -f6)}"
REMOTE_USER_HOME="${REMOTE_USER_HOME:-$(eval echo ~$REMOTE_USER)}"
AGENT_DIR="${AGENT_CONFIG_DIR:-/usr/local/share/agent-config}/devin"

echo "Installing Devin CLI (method: ${INSTALL_METHOD}, version: ${VERSION})..."

# Install curl and jq if not available
if ! command -v curl &> /dev/null || ! command -v jq &> /dev/null; then
    apt-get update -y && apt-get install -y curl jq && rm -rf /var/lib/apt/lists/*
fi

# Ensure devin --version failures (warnings, missing creds, etc.) never abort
# the feature build. We only care that the binary is installed and executable.
DEVIN_BIN="$HOME/.local/bin/devin"

run_upstream_script() {
    local script_path="$1"

    # The official installer ends with `... setup`, which invokes the
    # interactive `devin setup` wizard. In a non-interactive container build
    # there is no controlling TTY, so the wizard either hangs or aborts under
    # `set -e` and breaks the entire Codespace/devcontainer build. Strip the
    # final `setup` invocation line before executing.
    local patched_script
    patched_script="$(mktemp "${TMPDIR:-/tmp}/devin-install.XXXXXX.sh")"
    sed -E '/\$COMPILED_BIN_NAME"[[:space:]]+setup/d; /(^|[^A-Za-z_])devin[[:space:]]+setup([[:space:]]|$)/d' \
        "$script_path" > "$patched_script"
    chmod +x "$patched_script"

    if grep -Eq '\$COMPILED_BIN_NAME"[[:space:]]+setup|(^|[^A-Za-z_])devin[[:space:]]+setup([[:space:]]|$)' "$patched_script"; then
        echo "Error: failed to strip interactive 'devin setup' from upstream installer" >&2
        rm -f "$patched_script"
        return 1
    fi

    bash "$patched_script"
    local rc=$?
    rm -f "$patched_script"
    return $rc
}

manifest_field() {
    local manifest="$1" target="$2" field="$3"
    printf '%s' "$manifest" | jq -r --arg t "$target" --arg f "$field" '.platforms[$t][$f] // empty'
}

case "$INSTALL_METHOD" in
    script)
        INSTALLER="$(mktemp "${TMPDIR:-/tmp}/devin-cli-install.XXXXXX.sh")"
        curl --proto =https -fsSL https://cli.devin.ai/install.sh -o "$INSTALLER"
        run_upstream_script "$INSTALLER"
        rm -f "$INSTALLER"
        ;;

    binary)
        if [[ "$VERSION" == "latest" || -z "$VERSION" ]]; then
            VERSION_PATH="current"
        else
            VERSION_PATH="$VERSION"
        fi

        MANIFEST_URL="https://static.devin.ai/cli/${VERSION_PATH}/manifest.json"
        MANIFEST="$(curl --proto =https -fsSL "$MANIFEST_URL")"

        TARGET_RAW=$(uname -m)
        case "$TARGET_RAW" in
            x86_64)  TARGET="x86_64-unknown-linux" ;;
            aarch64) TARGET="aarch64-unknown-linux" ;;
            *)
                echo "Unsupported architecture: $TARGET_RAW" >&2
                exit 1
                ;;
        esac

        BUNDLE_URL=$(manifest_field "$MANIFEST" "$TARGET" "url")
        EXPECTED_SHA=$(manifest_field "$MANIFEST" "$TARGET" "sha256")

        if [[ -z "$BUNDLE_URL" || -z "$EXPECTED_SHA" ]]; then
            echo "Error: missing bundle URL or checksum in Devin manifest" >&2
            exit 1
        fi

        TMP_TARBALL="$(mktemp "${TMPDIR:-/tmp}/devin.XXXXXX.tar.gz")"
        TMP_EXTRACT="$(mktemp -d "${TMPDIR:-/tmp}/devin-extract.XXXXXX")"

        curl --proto =https -fSL "$BUNDLE_URL" -o "$TMP_TARBALL"

        ACTUAL_SHA=$(sha256sum "$TMP_TARBALL" | cut -d' ' -f1)
        if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
            echo "Error: checksum mismatch for Devin CLI tarball" >&2
            rm -rf "$TMP_TARBALL" "$TMP_EXTRACT"
            exit 1
        fi

        mkdir -p "$HOME/.local/bin"
        tar xzf "$TMP_TARBALL" -C "$TMP_EXTRACT"
        if [[ -x "$TMP_EXTRACT/devin/bin/devin" ]]; then
            cp "$TMP_EXTRACT/devin/bin/devin" "$DEVIN_BIN"
        elif [[ -x "$TMP_EXTRACT/bin/devin" ]]; then
            cp "$TMP_EXTRACT/bin/devin" "$DEVIN_BIN"
        else
            BIN_PATH=$(find "$TMP_EXTRACT" -type f -name devin -executable | head -n1)
            if [[ -z "$BIN_PATH" ]]; then
                echo "Error: could not locate devin binary in extracted tarball" >&2
                rm -rf "$TMP_TARBALL" "$TMP_EXTRACT"
                exit 1
            fi
            cp "$BIN_PATH" "$DEVIN_BIN"
        fi
        chmod +x "$DEVIN_BIN"

        rm -rf "$TMP_TARBALL" "$TMP_EXTRACT"
        ;;

    *)
        echo "Error: unknown INSTALLMETHOD '${INSTALL_METHOD}'" >&2
        exit 1
        ;;
esac

if [[ ! -e "$DEVIN_BIN" ]]; then
    echo "Devin CLI installation failed: binary not found at $DEVIN_BIN" >&2
    exit 1
fi

cp "$DEVIN_BIN" /usr/local/bin/devin
chmod +x /usr/local/bin/devin
echo "Devin CLI copied to /usr/local/bin/devin"

# Shared agent config
mkdir -p "$AGENT_DIR"
if id -u "$REMOTE_USER" >/dev/null 2>&1; then
    chown -R "$REMOTE_USER:$REMOTE_USER" "$AGENT_DIR"
fi

if [ -d "$REMOTE_USER_HOME" ]; then
    for target in "$REMOTE_USER_HOME/.devin" "$REMOTE_USER_HOME/.config/devin"; do
        if [ -e "$target" ] && [ ! -L "$target" ]; then
            mv "$target" "$AGENT_DIR/$(basename "$target")-legacy"
        fi
        parent=$(dirname "$target")
        mkdir -p "$parent"
        rm -f "$target"
        if id -u "$REMOTE_USER" >/dev/null 2>&1; then
            chown "$REMOTE_USER:$REMOTE_USER" "$parent" 2>/dev/null || true
            su -s /bin/bash - "$REMOTE_USER" -c "ln -sfn '$AGENT_DIR' '$target'" 2>/dev/null || true
        else
            ln -sfn "$AGENT_DIR" "$target"
        fi
    done
fi

set +e
if command -v devin >/dev/null 2>&1; then
    OUT=$(devin --version 2>&1)
    RC=$?
    if [[ $RC -eq 0 ]]; then
        echo "Devin CLI version: ${OUT}"
    else
        echo "Devin CLI: version check skipped (exit ${RC})"
    fi
else
    echo "Devin CLI: binary not on PATH; skipping version check"
fi
set -e

echo "Devin CLI installed successfully!"
