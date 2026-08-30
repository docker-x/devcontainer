#!/bin/bash
set -e

# Homebrew Installation Script for Devcontainers

REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-vscode}}"
HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
PACKAGES="${PACKAGES:-}"

echo "Installing Homebrew for user: $REMOTE_USER..."

# Ensure dependencies are present
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y curl ca-certificates git jq procps coreutils
    rm -rf /var/lib/apt/lists/*
fi

if ! command -v brew &>/dev/null; then
    # The official installer refuses to run as root, so run as the remote user.
    if ! id -u "$REMOTE_USER" >/dev/null 2>&1; then
        echo "Error: remote user '$REMOTE_USER' does not exist." >&2
        exit 1
    fi

    mkdir -p /home/linuxbrew
    chown -R "$REMOTE_USER:$REMOTE_USER" /home/linuxbrew

    su -s /bin/bash - "$REMOTE_USER" -c \
        'NONINTERACTIVE=1 /bin/bash -c "$(curl --proto =https -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
fi

# Expose Homebrew to all shells
cat > /etc/profile.d/homebrew.sh << EOF
export HOMEBREW_PREFIX="$HOMEBREW_PREFIX"
export PATH="$HOMEBREW_PREFIX/bin:\$PATH"
EOF
chmod +x /etc/profile.d/homebrew.sh

export PATH="$HOMEBREW_PREFIX/bin:$PATH"

# Fix: brew wrapper script uses readlink which may not be in PATH
# when invoked via su. Create a symlink in the brew bin directory.
if [ -x /usr/bin/readlink ] && [ ! -e "$HOMEBREW_PREFIX/bin/readlink" ]; then
    ln -sf /usr/bin/readlink "$HOMEBREW_PREFIX/bin/readlink"
fi

# Install requested packages
if [ -n "$PACKAGES" ]; then
    # Parse packages: try JSON array first, then comma-separated string
    if echo "$PACKAGES" | jq -r '.[]' 2>/dev/null | grep -q .; then
        PACKAGE_LIST=$(echo "$PACKAGES" | jq -r '.[]')
    else
        PACKAGE_LIST=$(echo "$PACKAGES" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi

    for pkg in $PACKAGE_LIST; do
        [ -z "$pkg" ] && continue
        echo "Installing Homebrew package: $pkg"
        su -s /bin/bash - "$REMOTE_USER" -c \
            "export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOMEBREW_PREFIX/bin:\$PATH'; brew install '$pkg' || brew upgrade '$pkg'"

        # Symlink formula binaries to /usr/local/bin for global access
        prefix=$(su -s /bin/bash - "$REMOTE_USER" -c \
            "export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOMEBREW_PREFIX/bin:\$PATH'; brew --prefix '$pkg' 2>/dev/null" || true)
        if [ -n "$prefix" ] && [ -d "$prefix/bin" ]; then
            for bin_file in "$prefix/bin"/*; do
                if [ -x "$bin_file" ]; then
                    ln -sf "$bin_file" "/usr/local/bin/$(basename "$bin_file")"
                fi
            done
        fi
    done
fi

echo "Homebrew installed successfully!"
