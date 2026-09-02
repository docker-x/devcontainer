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

CONFIG_DIR="${AGENT_CONFIG_DIR:-/usr/local/share/agent-config}"
REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-root}}"
REGISTRY_PATH="${REGISTRYPATH:-.devcontainer/mcp-servers.json}"

echo "Installing MCP Servers Registry applier..."

# Install configure-mcp.sh to /usr/local/bin
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
HOME_FALLBACK="/home/vscode"
_H="${HOME:-$HOME_FALLBACK}"
[ "$_H" = "/" ] && _H="$HOME_FALLBACK"
export HOME="$_H"

REGISTRY_PATH="${MCP_SERVERS_REGISTRY_PATH:-.devcontainer/mcp-servers.json}"
WORKSPACE_FOLDER="${WORKSPACE_FOLDER:-${PWD}}"

# Resolve registry path: try as-is, then relative to workspace folder
resolve_registry() {
    # If absolute path, use it directly
    case "$REGISTRY_PATH" in
        /*)
            if [ -f "$REGISTRY_PATH" ]; then
                echo "$REGISTRY_PATH"
                return 0
            fi
            return 1
            ;;
    esac
    # Try workspace folder first, then CWD-relative
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
    local tmp

    # Create file with empty mcpServers if it doesn't exist
    if [ ! -f "$config_file" ]; then
        mkdir -p "$(dirname "$config_file")"
        echo '{"mcpServers": {}}' > "$config_file"
    fi

    # Ensure mcpServers key exists
    if ! jq -e '.mcpServers' "$config_file" >/dev/null 2>&1; then
        tmp=$(jq '. + {"mcpServers": {}}' "$config_file")
        echo "$tmp" > "$config_file"
    fi

    # Merge: only set if not already present (don't overwrite user config)
    if jq -e --arg name "$server_name" '.mcpServers[$name]' "$config_file" >/dev/null 2>&1; then
        : # already exists, skip
    else
        tmp=$(jq --arg name "$server_name" --argjson entry "$entry_json" \
            '.mcpServers[$name] = $entry' "$config_file")
        echo "$tmp" > "$config_file"
    fi
}

# --- Helper: add a server to Codex config.toml ---
# Args: $1=config_file, $2=server_name, $3=entry_json
merge_into_toml() {
    local config_file="$1" server_name="$2" entry_json="$3"
    local has_url has_command

    has_url=$(echo "$entry_json" | jq -r 'has("url")')
    has_command=$(echo "$entry_json" | jq -r 'has("command")')

    # Create file if it doesn't exist
    if [ ! -f "$config_file" ]; then
        mkdir -p "$(dirname "$config_file")"
        touch "$config_file"
    fi

    # Skip if server already configured
    if grep -q "^\[mcp_servers\.$server_name\]" "$config_file" 2>/dev/null; then
        return 0
    fi

    # Append TOML block
    {
        echo ""
        echo "[mcp_servers.$server_name]"
        if [ "$has_url" = "true" ]; then
            echo "$entry_json" | jq -r '.url' | sed 's/^/url = "/; s/$/"/'
        fi
        if [ "$has_command" = "true" ]; then
            echo "$entry_json" | jq -r '.command' | sed 's/^/command = "/; s/$/"/'
            # args as TOML array
            echo "$entry_json" | jq -r 'if .args then "args = [" + ([.args[] | "\"" + . + "\""] | join(", ")) + "]" else empty end'
            # env as TOML inline table: env = { FOO = "bar", BAZ = "qux" }
            echo "$entry_json" | jq -r 'if .env then "env = { " + ([.env | to_entries[] | "\(.key) = \"\(.value)\""] | join(", ")) + " }" else empty end' 2>/dev/null || true
        fi
    } >> "$config_file"
}

# --- Agent adapters ---

apply_claude() {
    local claude_config="$HOME/.claude.json"
    if ! command -v claude >/dev/null 2>&1 && [ ! -f "$claude_config" ]; then
        return 0
    fi

    echo "configure-mcp: configuring Claude Code"
    for server_name in $(jq -r 'keys[]' "$REGISTRY_FILE"); do
        entry=$(jq -c --arg name "$server_name" '.[$name]' "$REGISTRY_FILE")
        has_url=$(echo "$entry" | jq -r 'has("url")')

        if [ "$has_url" = "true" ]; then
            # Claude requires type: "http" for remote servers
            adapted=$(echo "$entry" | jq -c '. + {"type": "http"}')
        else
            adapted="$entry"
        fi

        merge_into_json "$claude_config" "$server_name" "$adapted"
    done
}

apply_codex() {
    local codex_config="$HOME/.codex/config.toml"
    if ! command -v codex >/dev/null 2>&1 && [ ! -f "$codex_config" ]; then
        return 0
    fi

    echo "configure-mcp: configuring Codex"
    for server_name in $(jq -r 'keys[]' "$REGISTRY_FILE"); do
        entry=$(jq -c --arg name "$server_name" '.[$name]' "$REGISTRY_FILE")
        merge_into_toml "$codex_config" "$server_name" "$entry"
    done
}

apply_devin() {
    local devin_config="$HOME/.config/devin/mcp_config.json"
    if ! command -v devin >/dev/null 2>&1 && [ ! -f "$devin_config" ]; then
        return 0
    fi

    echo "configure-mcp: configuring Devin"
    for server_name in $(jq -r 'keys[]' "$REGISTRY_FILE"); do
        entry=$(jq -c --arg name "$server_name" '.[$name]' "$REGISTRY_FILE")
        has_url=$(echo "$entry" | jq -r 'has("url")')

        if [ "$has_url" = "true" ]; then
            # Devin uses "transport": "http" for remote servers
            adapted=$(echo "$entry" | jq -c '. + {"transport": "http"}')
        else
            adapted="$entry"
        fi

        merge_into_json "$devin_config" "$server_name" "$adapted"
    done
}

apply_cursor() {
    local cursor_config="$HOME/.cursor/mcp.json"
    if ! command -v cursor >/dev/null 2>&1 && [ ! -f "$cursor_config" ]; then
        return 0
    fi

    echo "configure-mcp: configuring Cursor"
    for server_name in $(jq -r 'keys[]' "$REGISTRY_FILE"); do
        entry=$(jq -c --arg name "$server_name" '.[$name]' "$REGISTRY_FILE")
        # Cursor: just url for remote, command+args for stdio — no type field needed
        merge_into_json "$cursor_config" "$server_name" "$entry"
    done
}

apply_copilot() {
    local copilot_config="$HOME/.copilot/mcp-config.json"
    if ! command -v copilot >/dev/null 2>&1 && [ ! -f "$copilot_config" ]; then
        return 0
    fi

    echo "configure-mcp: configuring GitHub Copilot"
    for server_name in $(jq -r 'keys[]' "$REGISTRY_FILE"); do
        entry=$(jq -c --arg name "$server_name" '.[$name]' "$REGISTRY_FILE")
        has_url=$(echo "$entry" | jq -r 'has("url")')

        if [ "$has_url" = "true" ]; then
            # Copilot requires type: "http" for remote servers
            adapted=$(echo "$entry" | jq -c '. + {"type": "http"}')
        else
            adapted=$(echo "$entry" | jq -c '. + {"type": "local"}')
        fi

        merge_into_json "$copilot_config" "$server_name" "$adapted"
    done
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

# Make registry path available in login shells
cat > /etc/profile.d/mcp-servers.sh << EOF
export MCP_SERVERS_REGISTRY_PATH="$REGISTRY_PATH"
EOF
chmod +x /etc/profile.d/mcp-servers.sh

# Also set in /etc/environment for non-login shells
if ! grep -q 'MCP_SERVERS_REGISTRY_PATH' /etc/environment 2>/dev/null; then
    echo "MCP_SERVERS_REGISTRY_PATH=$REGISTRY_PATH" >> /etc/environment
fi

# Ensure jq is available (configure-mcp.sh depends on it)
if ! command -v jq >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y jq && rm -rf /var/lib/apt/lists/*
fi

echo "MCP Servers Registry applier installed successfully!"
echo "  - configure-mcp.sh: /usr/local/bin/configure-mcp.sh"
echo "  - registry path: $REGISTRY_PATH"
echo "  - add to postStartCommand: configure-mcp.sh"
