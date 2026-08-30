#!/bin/bash
set -e

# Gas City Installation Script
# Installs Gas City (gc), beads (bd), and dolt directly from GitHub releases,
# plus jq and tmux via apt-get. No Homebrew dependency.

REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-root}}"
REMOTE_USER_HOME="${_REMOTE_USER_HOME:-$(getent passwd "$REMOTE_USER" 2>/dev/null | cut -d: -f6)}"
AGENT_DIR="${AGENT_CONFIG_DIR:-/usr/local/share/agent-config}/gascity"
GASCITY_VERSION="${VERSION:-latest}"

echo "Installing Gas City for user $REMOTE_USER..."

# ---------------------------------------------------------------------------
# Detect architecture
# ---------------------------------------------------------------------------
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
    x86_64|amd64) GOARCH="amd64" ;;
    aarch64|arm64) GOARCH="arm64" ;;
    *)
        echo "Error: unsupported architecture '$ARCH_RAW' for Gas City." >&2
        exit 1
        ;;
esac
echo "Detected architecture: $ARCH_RAW -> $GOARCH"

# ---------------------------------------------------------------------------
# apt-get dependencies: jq, tmux (flock ships with util-linux on Ubuntu)
# ---------------------------------------------------------------------------
echo "Installing apt dependencies (jq, tmux)..."
if ! command -v apt-get >/dev/null 2>&1; then
    echo "Warning: apt-get not found; skipping apt-based dependency install." >&2
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends jq tmux ca-certificates curl tar
    rm -rf /var/lib/apt/lists/*
fi

# flock is provided by util-linux, which is present on Ubuntu by default.
# Verify required tools are available (apt-get may have been skipped or failed)
for tool in jq curl tar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: required tool '$tool' not found. Install it manually or ensure apt-get is available." >&2
        exit 1
    fi
done
if ! command -v flock >/dev/null 2>&1; then
    echo "Warning: flock not found on PATH (util-linux expected on Ubuntu)." >&2
fi

# ---------------------------------------------------------------------------
# Helpers for resolving "latest" release tags from GitHub
# ---------------------------------------------------------------------------
github_latest_tag() {
    # $1 = owner/repo
    local repo="$1"
    local tag=""
    set +e
    tag="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
        | jq -r '.tag_name // empty' 2>/dev/null)"
    set -e
    if [ -z "$tag" ]; then
        # Fallback: parse the redirect target of the /latest tag URL.
        set +e
        tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
            "https://github.com/${repo}/releases/latest" 2>/dev/null \
            | sed -n 's|.*/tag/\(.*\)|\1|p')"
        set -e
    fi
    echo "$tag"
}

strip_v() {
    # $1 = version string, strips a leading 'v'
    echo "$1" | sed -E 's/^v//'
}

# ---------------------------------------------------------------------------
# Install Gas City (gc) from GitHub releases
# ---------------------------------------------------------------------------
install_gascity() {
    local version="$GASCITY_VERSION"
    local tag
    if [ "$version" = "latest" ] || [ -z "$version" ]; then
        tag="$(github_latest_tag "gastownhall/gascity")"
        if [ -z "$tag" ]; then
            echo "Error: could not resolve latest Gas City release tag." >&2
            exit 1
        fi
    else
        tag="v$(strip_v "$version")"
    fi
    local ver_no_v; ver_no_v="$(strip_v "$tag")"
    local asset="gascity_${ver_no_v}_linux_${GOARCH}.tar.gz"
    local url="https://github.com/gastownhall/gascity/releases/download/${tag}/${asset}"

    echo "Installing Gas City ${tag} from ${url}..."
    local tmpdir; tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN
    curl -fsSL "$url" -o "$tmpdir/$asset"
    tar -xzf "$tmpdir/$asset" -C "$tmpdir"

    if [ ! -f "$tmpdir/gc" ]; then
        echo "Error: gc binary not found in Gas City tarball." >&2
        exit 1
    fi
    install -m 0755 "$tmpdir/gc" /usr/local/bin/gc
    echo "Gas City ${tag} installed to /usr/local/bin/gc"
}

# ---------------------------------------------------------------------------
# Install Dolt from GitHub releases (storage backend for beads)
# ---------------------------------------------------------------------------
install_dolt() {
    local tag; tag="$(github_latest_tag "dolthub/dolt")"
    if [ -z "$tag" ]; then
        echo "Error: could not resolve latest Dolt release tag." >&2
        exit 1
    fi
    local asset="dolt-linux-${GOARCH}.tar.gz"
    local url="https://github.com/dolthub/dolt/releases/download/${tag}/${asset}"

    echo "Installing Dolt ${tag} from ${url}..."
    local tmpdir; tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN
    curl -fsSL "$url" -o "$tmpdir/$asset"
    tar -xzf "$tmpdir/$asset" -C "$tmpdir"

    # Dolt tarball layout: either ./bin/dolt or ./dolt
    local dolt_bin=""
    for candidate in "$tmpdir/bin/dolt" "$tmpdir/dolt" "$(find "$tmpdir" -type f -name dolt -perm -u+x | head -n1)"; do
        if [ -f "$candidate" ]; then
            dolt_bin="$candidate"
            break
        fi
    done
    if [ -z "$dolt_bin" ]; then
        echo "Error: dolt binary not found in Dolt tarball." >&2
        exit 1
    fi
    install -m 0755 "$dolt_bin" /usr/local/bin/dolt
    echo "Dolt ${tag} installed to /usr/local/bin/dolt"
}

# ---------------------------------------------------------------------------
# Install beads (bd) from GitHub releases
# ---------------------------------------------------------------------------
install_beads() {
    local tag; tag="$(github_latest_tag "gastownhall/beads")"
    if [ -z "$tag" ]; then
        echo "Error: could not resolve latest beads release tag." >&2
        exit 1
    fi
    local ver_no_v; ver_no_v="$(strip_v "$tag")"
    local asset="beads_${ver_no_v}_linux_${GOARCH}.tar.gz"
    local url="https://github.com/gastownhall/beads/releases/download/${tag}/${asset}"

    echo "Installing beads ${tag} from ${url}..."
    local tmpdir; tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN
    curl -fsSL "$url" -o "$tmpdir/$asset"
    tar -xzf "$tmpdir/$asset" -C "$tmpdir"

    # beads tarball layout: either ./bd or ./bin/bd
    local bd_bin=""
    for candidate in "$tmpdir/bd" "$tmpdir/bin/bd" "$(find "$tmpdir" -type f -name bd -perm -u+x | head -n1)"; do
        if [ -f "$candidate" ]; then
            bd_bin="$candidate"
            break
        fi
    done
    if [ -z "$bd_bin" ]; then
        echo "Error: bd binary not found in beads tarball." >&2
        exit 1
    fi
    install -m 0755 "$bd_bin" /usr/local/bin/bd
    echo "beads ${tag} installed to /usr/local/bin/bd"
}

install_gascity
install_dolt
install_beads

# ---------------------------------------------------------------------------
# Verify installs (non-fatal)
# ---------------------------------------------------------------------------
set +e
echo "gc found at: $(command -v gc || echo 'not found')"
gc version 2>/dev/null || echo "gc version check skipped"
echo "dolt found at: $(command -v dolt || echo 'not found')"
dolt version 2>/dev/null || echo "dolt version check skipped"
echo "bd found at: $(command -v bd || echo 'not found')"
bd version 2>/dev/null || echo "bd version check skipped"
set -e

# ---------------------------------------------------------------------------
# Shared agent config for Gas City
# ---------------------------------------------------------------------------
mkdir -p "$AGENT_DIR"
if id -u "$REMOTE_USER" >/dev/null 2>&1; then
    chown -R "$REMOTE_USER:" "$AGENT_DIR"
fi

if [ -d "$REMOTE_USER_HOME" ]; then
    if [ -e "$REMOTE_USER_HOME/.gascity" ] && [ ! -L "$REMOTE_USER_HOME/.gascity" ]; then
        mv "$REMOTE_USER_HOME/.gascity" "$AGENT_DIR/legacy-gascity"
    fi
    rm -f "$REMOTE_USER_HOME/.gascity"
    su -s /bin/bash - "$REMOTE_USER" -c "ln -sfn '$AGENT_DIR' '$REMOTE_USER_HOME/.gascity'" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Entrypoint for container startup
# ---------------------------------------------------------------------------
mkdir -p /usr/local/share/gascity
cp scripts/entrypoint.sh /usr/local/share/gascity/entrypoint.sh
chmod +x /usr/local/share/gascity/entrypoint.sh

AUTOREGISTER="${AUTOREGISTER:-false}"
if [ "$AUTOREGISTER" = "true" ]; then
    echo "true" > /usr/local/share/gascity/autoregister_enabled
else
    echo "false" > /usr/local/share/gascity/autoregister_enabled
fi
chmod 644 /usr/local/share/gascity/autoregister_enabled

echo "Gas City installed successfully!"
