#!/bin/bash
set -e

# Caddy Proxy Feature — install script
# Installs Caddy as a reverse proxy for dev server previews.
# Caddy listens on a single port and routes to multiple dev servers
# via path prefixes. Routes are hot-reloadable via the admin API or
# the proxy-add/proxy-list/proxy-rm helper scripts.

REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-root}}"
REMOTE_USER_HOME="${_REMOTE_USER_HOME:-$(getent passwd "$REMOTE_USER" 2>/dev/null | cut -d: -f6)}"
REMOTE_USER_HOME="${REMOTE_USER_HOME:-/home/vscode}"

LISTEN_PORT="${LISTENPORT:-3000}"
ADMIN_PORT="${ADMINPORT:-2019}"

echo "caddy-proxy: installing Caddy..."

# Install Caddy as a single binary from GitHub releases.
# Determine architecture.
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  CADDY_ARCH="amd64" ;;
    aarch64) CADDY_ARCH="arm64" ;;
    armv7l)  CADDY_ARCH="arm" ;;
    *)       echo "caddy-proxy: unsupported architecture $ARCH" >&2; exit 1 ;;
esac

CADDY_VERSION="2.8.4"
CADDY_URL="https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${CADDY_ARCH}.tar.gz"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

curl --proto =https -fsSL "$CADDY_URL" -o "$TMPDIR/caddy.tar.gz"
tar -xzf "$TMPDIR/caddy.tar.gz" -C "$TMPDIR"
install -m 0755 "$TMPDIR/caddy" /usr/local/bin/caddy

# Verify
caddy version

echo "caddy-proxy: creating Caddyfile and helper scripts..."

# Default Caddyfile — listens on the configured port, admin API on admin port.
# Routes are added dynamically via proxy-add.
CADDY_CONFIG_DIR="/usr/local/share/caddy-proxy"
mkdir -p "$CADDY_CONFIG_DIR"

cat > "$CADDY_CONFIG_DIR/Caddyfile" <<EOF
{
    admin localhost:${ADMIN_PORT}
}

:${LISTEN_PORT} {
    respond "caddy-proxy running on :${LISTEN_PORT}. Use 'proxy-add <path> <host:port>' to add routes." 200
}
EOF

# Helper script: proxy-add <path> <host:port>
# Adds a reverse proxy route via Caddy's JSON API.
# Reads current routes, prepends the new route, writes back via PUT.
cat > /usr/local/bin/proxy-add <<'SCRIPT'
#!/bin/bash
set -e

ADMIN_PORT="${CADDY_ADMIN_PORT:-2019}"

if [ $# -lt 2 ]; then
    echo "Usage: proxy-add <path-prefix> <host:port> [strip-prefix]"
    echo "  e.g. proxy-add /api localhost:8080"
    echo "       proxy-add /docs localhost:3001 true"
    exit 1
fi

PATH_PREFIX="$1"
UPSTREAM="$2"
STRIP="${3:-false}"

# Normalize path — ensure leading slash, no trailing slash
PATH_PREFIX="/$(echo "$PATH_PREFIX" | sed 's|^/||; s|/$||')"

# Build the new route JSON.
if [ "$STRIP" == "true" ]; then
    NEW_ROUTE=$(cat <<JSON
{
    "match": [{"path": ["${PATH_PREFIX}/*"]}],
    "handle": [
        {"handler": "rewrite", "strip_path_prefix": "${PATH_PREFIX}"},
        {"handler": "reverse_proxy", "upstreams": [{"dial": "${UPSTREAM}"}]}
    ]
}
JSON
)
else
    NEW_ROUTE=$(cat <<JSON
{
    "match": [{"path": ["${PATH_PREFIX}/*"]}],
    "handle": [
        {"handler": "reverse_proxy", "upstreams": [{"dial": "${UPSTREAM}"}]}
    ]
}
JSON
)
fi

# Read current routes, prepend new route, write back via PATCH.
# Caddy evaluates routes in order — first match wins, so new routes
# must come before the default catch-all.
CURRENT=$(curl -s "http://localhost:${ADMIN_PORT}/config/apps/http/servers/srv0/routes" 2>/dev/null || echo "[]")

# Build new array: [new_route, ...current_routes]
NEW_ROUTES=$(echo "$CURRENT" | jq --argjson new "$NEW_ROUTE" -c '[$new] + .')

# Use PATCH to replace the entire routes array (PUT returns 409 if key exists)
curl -s "http://localhost:${ADMIN_PORT}/config/apps/http/servers/srv0/routes" \
    -X PATCH \
    -H "Content-Type: application/json" \
    -d "$NEW_ROUTES" >/dev/null

echo "proxy-add: ${PATH_PREFIX} → ${UPSTREAM} (strip=${STRIP})"
SCRIPT
chmod 0755 /usr/local/bin/proxy-add

# Helper script: proxy-list
# Lists all routes configured in Caddy.
cat > /usr/local/bin/proxy-list <<'SCRIPT'
#!/bin/bash
set -e

ADMIN_PORT="${CADDY_ADMIN_PORT:-2019}"

ROUTES=$(curl -s "http://localhost:${ADMIN_PORT}/config/apps/http/servers/srv0/routes" 2>/dev/null)

if [ -z "$ROUTES" ] || [ "$ROUTES" == "null" ]; then
    echo "No routes configured. Use 'proxy-add <path> <host:port>'."
    exit 0
fi

echo "$ROUTES" | jq -r '.[] |
    "  \(.match[0].path[0] // "/*") → \([.handle[] | .upstreams[0].dial // .handler] | join(" → "))"' 2>/dev/null || \
echo "$ROUTES"
SCRIPT
chmod 0755 /usr/local/bin/proxy-list

# Helper script: proxy-rm <path>
# Removes a route by path prefix.
cat > /usr/local/bin/proxy-rm <<'SCRIPT'
#!/bin/bash
set -e

ADMIN_PORT="${CADDY_ADMIN_PORT:-2019}"

if [ $# -lt 1 ]; then
    echo "Usage: proxy-rm <path-prefix>"
    exit 1
fi

PATH_PREFIX="$1"
PATH_PREFIX="/$(echo "$PATH_PREFIX" | sed 's|^/||; s|/$||')"

# Find the route index by path
INDEX=$(curl -s "http://localhost:${ADMIN_PORT}/config/apps/http/servers/srv0/routes" | \
    jq -r "to_entries | map(select(.value.match[0].path[0] == \"${PATH_PREFIX}/*\")) | .[0].key // empty" 2>/dev/null)

if [ -z "$INDEX" ]; then
    echo "proxy-rm: no route found for ${PATH_PREFIX}"
    exit 1
fi

curl -s -X DELETE "http://localhost:${ADMIN_PORT}/config/apps/http/servers/srv0/routes/${INDEX}" >/dev/null
echo "proxy-rm: removed ${PATH_PREFIX}"
SCRIPT
chmod 0755 /usr/local/bin/proxy-rm

# Entrypoint script: starts Caddy in background with the Caddyfile.
cat > /usr/local/bin/caddy-proxy-start <<'SCRIPT'
#!/bin/bash
set -e

CADDY_CONFIG_DIR="${CADDY_CONFIG_DIR:-/usr/local/share/caddy-proxy}"
CADDYFILE="${CADDYFILE:-$CADDY_CONFIG_DIR/Caddyfile}"

if pgrep -x caddy >/dev/null 2>&1; then
    echo "caddy-proxy: already running (pid $(pgrep -x caddy))"
    exit 0
fi

echo "caddy-proxy: starting Caddy..."
caddy run --config "$CADDYFILE" --adapter caddyfile &
echo $! > "${HOME}/.caddy-proxy.pid"
echo "caddy-proxy: started (pid $(cat "${HOME}/.caddy-proxy.pid"))"
SCRIPT
chmod 0755 /usr/local/bin/caddy-proxy-start

# Profile script: expose Caddy env vars and start hint.
cat > /etc/profile.d/caddy-proxy.sh <<EOF
export CADDY_LISTEN_PORT=${LISTEN_PORT}
export CADDY_ADMIN_PORT=${ADMIN_PORT}
export CADDY_CONFIG_DIR=${CADDY_CONFIG_DIR}
# Auto-start Caddy on first shell if not running
if ! pgrep -x caddy >/dev/null 2>&1; then
    caddy-proxy-start >/dev/null 2>&1
fi
EOF
chmod 0755 /etc/profile.d/caddy-proxy.sh

# Also set in /etc/environment for non-login shells.
cat >> /etc/environment <<EOF
CADDY_LISTEN_PORT=${LISTEN_PORT}
CADDY_ADMIN_PORT=${ADMIN_PORT}
CADDY_CONFIG_DIR=${CADDY_CONFIG_DIR}
EOF

echo "caddy-proxy: installed successfully!"
echo "  binary:    /usr/local/bin/caddy"
echo "  config:    $CADDY_CONFIG_DIR/Caddyfile"
echo "  listen:    :${LISTEN_PORT}"
echo "  admin API: localhost:${ADMIN_PORT}"
echo ""
echo "Commands:"
echo "  proxy-add /api localhost:8080    # add a route"
echo "  proxy-list                       # list routes"
echo "  proxy-rm /api                    # remove a route"
echo "  caddy-proxy-start                # start Caddy"
