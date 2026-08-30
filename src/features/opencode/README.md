# OpenCode AI

This devcontainer feature installs [OpenCode](https://opencode.ai), an
open-source AI coding agent for terminal-based development.

## Usage

Add the feature to your `devcontainer.json`:

```jsonc
{
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
  "features": {
    "ghcr.io/devcontainers/features/node:latest": {},
    "ghcr.io/docker-x/devcontainers/agent-config:1": {},
    "ghcr.io/docker-x/devcontainers/opencode:1": {
      "version": "latest",
      "installMethod": "npm"
    }
  }
}
```

### Options

| Option          | Type   | Default   | Description                                                                                      |
| --------------- | ------ | --------- | ------------------------------------------------------------------------------------------------ |
| `version`       | string | `latest`  | Version of OpenCode to install. Use `latest` or a specific published version.                    |
| `installMethod` | enum   | `npm`     | Install via `npm` (`opencode-ai` package) or via the official install `script`.                  |

## What it does

1. Installs OpenCode either via `npm install -g opencode-ai` (default) or via
   the official install script (`curl -fsSL https://opencode.ai/install.sh | bash`).
2. Copies the `opencode` binary to `/usr/local/bin/opencode` for system-wide
   access.
3. Verifies the installation with `opencode --version`.
4. Creates a shared config directory under `AGENT_CONFIG_DIR` and symlinks
   `~/.opencode` and `~/.config/opencode` to it so OpenCode keeps its config
   alongside other agents.

## Requirements

- For the `npm` install method, Node.js and `npm` must already be installed in
  the image. The feature declares `installsAfter` the official `node` feature.
- The `agent-config` feature is required (`dependsOn`) and creates the shared
  `AGENT_CONFIG_DIR` used for config symlinks.
- The `script` install method only requires `curl`.

## Post-install

Once installed, run `opencode` in the terminal to start the agent. Run
`opencode --help` to see the available subcommands.
