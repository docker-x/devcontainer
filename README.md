# docker-x/devcontainers

Devcontainer features and templates inspired by `gascity` and AI-agent tooling. All agent features share a common configuration folder so multiple agents can coexist in the same workspace.

## Features

| Feature | Description |
| ------- | ----------- |
| `agent-config` | Creates `AGENT_CONFIG_DIR` (`/usr/local/share/agent-config`) and prepares it for shared use. |
| `homebrew` | Installs Homebrew on Linux with optional package list. |
| `gascity` | Installs and validates Gas City. |
| `devin` | Installs the Devin CLI. |
| `claude` | Configures Anthropic Claude SDK. |
| `cursor` | Installs the Cursor Agent CLI. |
| `bob` | Installs Bob Shell. |
| `bun` | Installs the Bun JavaScript runtime. |
| `kilo` | Installs the Kilo CLI. |
| `playwright` | Installs Playwright system dependencies. |
| `sacp-conductor` | Installs `sacp-conductor` via Cargo. |

## Templates

| Template | Description |
| -------- | ----------- |
| `agent-base` | A base workspace with common AI agents sharing `AGENT_CONFIG_DIR`. |
| `gascity-workspace` | A workspace for Gas City development with Bun and Playwright. |

## Shared agent config

All agent features depend on `agent-config` and create a subfolder under `AGENT_CONFIG_DIR`. Their usual home-directory config locations are symlinked to that subfolder, so agents keep their configs in one place and can be used side-by-side.

## Publishing

Run the `Release Dev Container Features & Templates` workflow manually from the Actions tab. Features are published to `ghcr.io/docker-x/devcontainers/<feature>` and templates to `ghcr.io/docker-x/devcontainers/templates/<template>`.

## Usage

```jsonc
{
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
  "features": {
    "ghcr.io/docker-x/devcontainers/agent-config:1": {},
    "ghcr.io/docker-x/devcontainers/devin:1": {},
    "ghcr.io/docker-x/devcontainers/gascity:1": {}
  },
  "remoteUser": "vscode"
}
```
