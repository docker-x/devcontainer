#!/bin/bash
set -e

# MCP Servers Registry
# Installs configure-mcp.sh — an idempotent applier that reads a JSON registry
# of MCP servers and merges them into each detected agent's native config.
#
# The registry file is a plain JSON file in the project (default:
# .devcontainer/mcp-servers.json), not a feature option. This avoids the
# devcontainer feature spec limitation (options can only be string/boolean,
# not objects) and keeps the registry human-readable and version-controlled.
#
# configure-mcp.sh is designed to run from postStartCommand (after PVC mount),
# not at build time — agent config files live in the PVC-backed home directory
# and would be overwritten by the mount if written during build.

REGISTRY_PATH="${REGISTRYPATH:-.devcontainer/mcp-servers.json}"

echo "Installing MCP Servers Registry applier..."

# Copy the registry file into the image at build time so it's available
# at runtime regardless of which workspace/project is active. The file
# is copied to AGENT_CONFIG_DIR (shared config directory).
CONFIG_DIR="${AGENT_CONFIG_DIR:-/usr/local/share/agent-config}"
mkdir -p "$CONFIG_DIR"

# Try to find and copy the registry file from the build context
_BUILD_REGISTRY=""
for candidate in \
    "$_DEVCONTAINER_BUILD_CONTEXT/$REGISTRY_PATH" \
    "$_REMOTE_USER_HOME/$REGISTRY_PATH" \
    "$PWD/$REGISTRY_PATH" \
    "$REGISTRY_PATH"; do
    if [ -f "$candidate" ]; then
        _BUILD_REGISTRY="$candidate"
        break
    fi
done

if [ -n "$_BUILD_REGISTRY" ]; then
    cp "$_BUILD_REGISTRY" "$CONFIG_DIR/mcp-servers.json"
    echo "MCP Servers Registry: copied $_BUILD_REGISTRY → $CONFIG_DIR/mcp-servers.json"
else
    echo "MCP Servers Registry: registry file '$REGISTRY_PATH' not found at build time"
    echo "  configure-mcp.sh will look for it at runtime relative to the workspace"
fi

# Install configure-mcp.sh to /usr/local/bin
rm -f /usr/local/bin/configure-mcp.sh
cat > /usr/local/bin/configure-mcp.sh << 'APPLIER_EOF'
#!/bin/bash
set -euo pipefail

# configure-mcp.sh — idempotent MCP server registry applier
#
# Reads a JSON registry of MCP servers and merges them into each detected
# agent's native config format. Designed to run from postStartCommand.
#
# Registry format (agent-agnostic):
#   {
#     "deepwiki": { "url": "https://mcp.deepwiki.com/mcp" },
#     "hindsight": {
#       "command": "node",
#       "args": ["/path/to/server.js"],
#       "env": { "KEY": "value" }
#     }
#   }
#
# Entries with a "url" key are remote (HTTP/SSE) servers.
# Entries with a "command" key are local (stdio) servers.
#
# Supported agents (auto-detected):
#   Claude Code  → ~/.claude.json          (mcpServers, type: "http" for remote)
#   Codex        → ~/.codex/config.toml    ([mcp_servers.*], TOML)
#   Devin        → ~/.config/devin/mcp_config.json (mcpServers, transport: "http")
#   Cursor       → ~/.cursor/mcp.json      (mcpServers, url only for remote)
#   Copilot      → ~/.copilot/mcp-config.json (mcpServers, type: "http" for remote)

# Fix HOME for OpenShift restricted SCC (sets HOME=/)
# Resolve from current UID's passwd entry instead of hardcoding /home/vscode
HOME_FALLBACK="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
HOME_FALLBACK="${HOME_FALLBACK:-/home/vscode}"
_H="${HOME:-$HOME_FALLBACK}"
[ "$_H" = "/" ] && _H="$HOME_FALLBACK"
export HOME="$_H"

REGISTRY_PATH="${MCP_SERVERS_REGISTRY_PATH:-.devcontainer/mcp-servers.json}"
WORKSPACE_FOLDER="${WORKSPACE_FOLDER:-${PWD}}"

# Resolve registry path: check AGENT_CONFIG_DIR first (baked at build time),
# then try the configured path relative to workspace folder and CWD.
resolve_registry() {
    # 1. Check AGENT_CONFIG_DIR for a baked-in registry (always available)
    local baked="${AGENT_CONFIG_DIR:-/usr/local/share/agent-config}/mcp-servers.json"
    if [ -f "$baked" ]; then
        echo "$baked"
        return 0
    fi
    # 2. If absolute path, use it directly
    case "$REGISTRY_PATH" in
        /*)
            if [ -f "$REGISTRY_PATH" ]; then
                echo "$REGISTRY_PATH"
                return 0
            fi
            return 1
            ;;
    esac
    # 3. Try workspace folder first, then CWD-relative
    local candidates=(
        "$WORKSPACE_FOLDER/$REGISTRY_PATH"
        "$REGISTRY_PATH"
    )
    for candidate in "${candidates[@]}"; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

REGISTRY_FILE="$(resolve_registry || true)"

if [ -z "$REGISTRY_FILE" ]; then
    echo "configure-mcp: registry file '$REGISTRY_PATH' not found, skipping"
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "configure-mcp: jq not available, skipping"
    exit 0
fi

# Validate registry is valid JSON with at least one server
SERVER_COUNT=$(jq -r 'length' "$REGISTRY_FILE" 2>/dev/null || echo "0")
if [ "$SERVER_COUNT" = "0" ]; then
    echo "configure-mcp: no servers in registry, skipping"
    exit 0
fi

echo "configure-mcp: applying $SERVER_COUNT servers from $REGISTRY_FILE"

# --- Helper: merge a server entry into a JSON config file's mcpServers ---
# Args: $1=config_file, $2=server_name, $3=server_entry_json
merge_into_json() {
    local config_file="$1" server_name="$2" entry_json="$3"
    local tmp tmp_file old_mode lock_file="${config_file}.lock"

    # Create parent directory before opening lock file (flock redirect fails otherwise)
    mkdir -p "$(dirname "$config_file")"

    (
        flock -x 200

        # Create file with empty mcpServers if it doesn't exist
        if [ ! -f "$config_file" ]; then
            echo '{"mcpServers": {}}' > "$config_file"
        fi

        # Capture original file mode to preserve it across atomic replacement
        old_mode=$(stat -c '%a' "$config_file" 2>/dev/null || echo "644")
        tmp_file="${config_file}.tmp.$$"

        # Ensure mcpServers key exists (atomic write via temp file + mv)
        if ! jq -e '.mcpServers' "$config_file" >/dev/null 2>&1; then
            tmp=$(jq '. + {"mcpServers": {}}' "$config_file")
            echo "$tmp" > "$tmp_file" && chmod "$old_mode" "$tmp_file" && mv "$tmp_file" "$config_file"
        fi

        # Merge: only set if not already present (don't overwrite user config)
        if jq -e --arg name "$server_name" '.mcpServers[$name]' "$config_file" >/dev/null 2>&1; then
            : # already exists, skip
        else
            tmp=$(jq --arg name "$server_name" --argjson entry "$entry_json" \
                '.mcpServers[$name] = $entry' "$config_file")
            echo "$tmp" > "$tmp_file" && chmod "$old_mode" "$tmp_file" && mv "$tmp_file" "$config_file"
        fi
    ) 200>"$lock_file"
}

# --- Helper: add a server to Codex config.toml ---
# Args: $1=config_file, $2=server_name, $3=entry_json
merge_into_toml() {
    local config_file="$1" server_name="$2" entry_json="$3"
    local has_url has_command toml_key lock_file="${config_file}.lock"

    has_url=$(echo "$entry_json" | jq -r 'has("url")')
    has_command=$(echo "$entry_json" | jq -r 'has("command")')
    # Quoted key is valid TOML for any server name (handles dots, spaces, etc.)
    toml_key=$(printf '%s' "$server_name" | jq -Rr '@json')

    # Create parent directory before opening lock file (flock redirect fails otherwise)
    mkdir -p "$(dirname "$config_file")"

    (
        flock -x 200

        # Create file if it doesn't exist
        if [ ! -f "$config_file" ]; then
            touch "$config_file"
        fi

        # Skip if server already configured — check both quoted and unquoted forms.
        # Use awk to normalize lines (strip comments and whitespace) before comparing,
        # so headers with trailing whitespace or inline comments are still detected.
        # The quoted form ([mcp_servers."name"]) handles all valid TOML keys;
        # the unquoted form ([mcp_servers.name]) is only checked for simple bare keys
        # (A-Za-z0-9_-), since names with dots create different TOML semantics when
        # unquoted (nested tables vs single quoted key).
        # Use ENVIRON instead of -v to avoid awk escape processing for names
        # containing backslashes or other special characters.
        local header="[mcp_servers.$toml_key]"
        local bare_header=""
        if printf '%s' "$server_name" | grep -qE '^[A-Za-z0-9_-]+$'; then
            bare_header="[mcp_servers.$server_name]"
        fi
        if HEADER="$header" BARE_HEADER="$bare_header" awk '
            { sub(/#.*$/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 == ENVIRON["HEADER"] || (ENVIRON["BARE_HEADER"] != "" && $0 == ENVIRON["BARE_HEADER"])) { found = 1; exit } }
            END { exit !found }
        ' "$config_file" 2>/dev/null; then
            return 0
        fi

        # Build TOML block and write atomically (temp file + mv, like merge_into_json).
        # This prevents partial writes on interruption from corrupting config.toml.
        local tmp_file="${config_file}.tmp.$$"
        cp -p "$config_file" "$tmp_file"
        {
            echo ""
            echo "[mcp_servers.$toml_key]"
            if [ "$has_url" = "true" ]; then
                # Use jq to produce a properly quoted TOML string value
                echo "$entry_json" | jq -r '"url = " + (.url | @json)'
            fi
            if [ "$has_command" = "true" ]; then
                echo "$entry_json" | jq -r '"command = " + (.command | @json)'
                # args as TOML array with proper escaping
                echo "$entry_json" | jq -r 'if .args then "args = [" + ([.args[] | @json] | join(", ")) + "]" else empty end'
                # env as TOML inline table with proper escaping (quote keys too)
                echo "$entry_json" | jq -r 'if .env then "env = { " + ([.env | to_entries[] | (.key | @json) + " = " + (.value | @json)] | join(", ")) + " }" else empty end' 2>/dev/null || true
            fi
        } >> "$tmp_file"
        mv "$tmp_file" "$config_file"
    ) 200>"$lock_file"
}

# --- Agent adapters ---

apply_claude() {
    local claude_config="$HOME/.claude.json"
    if ! command -v claude >/dev/null 2>&1 && [ ! -f "$claude_config" ]; then
        return 0
    fi

    echo "configure-mcp: configuring Claude Code"
    while IFS= read -r server_name; do
        entry=$(jq -c --arg name "$server_name" '.[$name]' "$REGISTRY_FILE")
        has_url=$(echo "$entry" | jq -r 'has("url")')

        if [ "$has_url" = "true" ]; then
            # Claude requires type: "http" for remote servers
            adapted=$(echo "$entry" | jq -c '. + {"type": "http"}')
        else
            adapted="$entry"
        fi

        merge_into_json "$claude_config" "$server_name" "$adapted"
    done < <(jq -r 'keys[]' "$REGISTRY_FILE")
}

apply_codex() {
    local codex_config="$HOME/.codex/config.toml"
    if ! command -v codex >/dev/null 2>&1 && [ ! -f "$codex_config" ]; then
        return 0
    fi

    echo "configure-mcp: configuring Codex"
    while IFS= read -r server_name; do
        entry=$(jq -c --arg name "$server_name" '.[$name]' "$REGISTRY_FILE")
        merge_into_toml "$codex_config" "$server_name" "$entry"
    done < <(jq -r 'keys[]' "$REGISTRY_FILE")
}

apply_devin() {
    local devin_config="$HOME/.config/devin/mcp_config.json"
    if ! command -v devin >/dev/null 2>&1 && [ ! -f "$devin_config" ]; then
        return 0
    fi

    echo "configure-mcp: configuring Devin"
    while IFS= read -r server_name; do
        entry=$(jq -c --arg name "$server_name" '.[$name]' "$REGISTRY_FILE")
        has_url=$(echo "$entry" | jq -r 'has("url")')

        if [ "$has_url" = "true" ]; then
            # Devin uses "transport": "http" for remote servers
            adapted=$(echo "$entry" | jq -c '. + {"transport": "http"}')
        else
            adapted="$entry"
        fi

        merge_into_json "$devin_config" "$server_name" "$adapted"
    done < <(jq -r 'keys[]' "$REGISTRY_FILE")
}

apply_cursor() {
    local cursor_config="$HOME/.cursor/mcp.json"
    if ! command -v cursor >/dev/null 2>&1 && [ ! -f "$cursor_config" ]; then
        return 0
    fi

    echo "configure-mcp: configuring Cursor"
    while IFS= read -r server_name; do
        entry=$(jq -c --arg name "$server_name" '.[$name]' "$REGISTRY_FILE")
        # Cursor: just url for remote, command+args for stdio — no type field needed
        merge_into_json "$cursor_config" "$server_name" "$entry"
    done < <(jq -r 'keys[]' "$REGISTRY_FILE")
}

apply_copilot() {
    local copilot_config="$HOME/.copilot/mcp-config.json"
    if ! command -v copilot >/dev/null 2>&1 && [ ! -f "$copilot_config" ]; then
        return 0
    fi

    echo "configure-mcp: configuring GitHub Copilot"
    while IFS= read -r server_name; do
        entry=$(jq -c --arg name "$server_name" '.[$name]' "$REGISTRY_FILE")
        has_url=$(echo "$entry" | jq -r 'has("url")')

        if [ "$has_url" = "true" ]; then
            # Copilot requires type: "http" for remote servers
            adapted=$(echo "$entry" | jq -c '. + {"type": "http"}')
        else
            adapted=$(echo "$entry" | jq -c '. + {"type": "local"}')
        fi

        merge_into_json "$copilot_config" "$server_name" "$adapted"
    done < <(jq -r 'keys[]' "$REGISTRY_FILE")
}

# --- Run all adapters (each is a no-op if agent not detected) ---
apply_claude
apply_codex
apply_devin
apply_cursor
apply_copilot

echo "configure-mcp: done"
APPLIER_EOF

chmod +x /usr/local/bin/configure-mcp.sh

# Write the default registry path to an env file that configure-mcp.sh sources.
# This avoids sed-based string interpolation (vulnerable to delimiter/injection
# when the path contains special characters). printf %q produces safe shell quoting.
# postStartCommand runs in a non-login shell that doesn't source /etc/profile.d,
# so the environment export alone is not sufficient. The env var remains as
# an override for runtime customization.
CONFIG_DIR="${AGENT_CONFIG_DIR:-/usr/local/share/agent-config}"
mkdir -p "$CONFIG_DIR"
rm -f "$CONFIG_DIR/mcp-registry-path.env"
printf 'MCP_SERVERS_REGISTRY_DEFAULT=%q\n' "$REGISTRY_PATH" > "$CONFIG_DIR/mcp-registry-path.env"

# Make registry path available in login shells (use printf %q for safe quoting)
rm -f /etc/profile.d/mcp-servers.sh
printf 'export MCP_SERVERS_REGISTRY_PATH=%q\n' "$REGISTRY_PATH" > /etc/profile.d/mcp-servers.sh
chmod +x /etc/profile.d/mcp-servers.sh

# Also set in /etc/environment for non-login shells (match full assignment to
# avoid false positives from comments or similarly named variables).
# Note: /etc/environment is parsed by PAM's pam_env, not by a shell — it does
# not interpret shell quoting/escaping. Use plain double-quoted values, not %q.
if ! grep -qE '^[[:space:]]*MCP_SERVERS_REGISTRY_PATH=' /etc/environment 2>/dev/null; then
    printf 'MCP_SERVERS_REGISTRY_PATH="%s"\n' "$REGISTRY_PATH" >> /etc/environment
fi

# Ensure jq is available (configure-mcp.sh depends on it)
if ! command -v jq >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y jq && rm -rf /var/lib/apt/lists/*
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache jq
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y jq
    elif command -v yum >/dev/null 2>&1; then
        yum install -y jq
    else
        echo "Warning: jq not found and no supported package manager available" >&2
    fi
fi

echo "MCP Servers Registry applier installed successfully!"
echo "  - configure-mcp.sh: /usr/local/bin/configure-mcp.sh"
echo "  - registry path: $REGISTRY_PATH"
echo "  - add to postStartCommand: configure-mcp.sh"
