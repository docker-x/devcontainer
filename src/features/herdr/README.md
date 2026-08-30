# Herdr

This devcontainer feature installs [Herdr](https://herdr.ai), an AI agent herd
orchestration tool for coordinating multiple coding agents.

## Usage

Add the feature to your `devcontainer.json`:

```jsonc
{
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
  "features": {
    "ghcr.io/devcontainers/features/node:latest": {},
    "ghcr.io/docker-x/devcontainers/agent-config:1": {},
    "ghcr.io/docker-x/devcontainers/herdr:1": {
      "version": "latest"
    }
  }
}
```

### Options

| Option    | Type   | Default   | Description                                                                          |
| --------- | ------ | --------- | ------------------------------------------------------------------------------------ |
| `version` | string | `latest`  | Version of Herdr to install. Use `latest` or a specific published version.           |

## What it does

1. Attempts to install Herdr globally via `npm install -g herdr`.
2. If npm is unavailable or the npm install fails, falls back to the official
   install script (`curl -fsSL https://herdr.ai/install.sh | bash`).
3. Copies the `herdr` binary to `/usr/local/bin/herdr` for system-wide access.
4. Verifies the installation with `herdr --version`.
5. Creates a shared config directory under `AGENT_CONFIG_DIR` and symlinks
   `~/.herdr` and `~/.config/herdr` to it so Herdr keeps its config alongside
   other agents.

## Requirements

- Node.js and `npm` are recommended but not strictly required: the feature
  falls back to the curl install script when npm is missing. The feature
  declares `installsAfter` the official `node` feature, so list that feature
  before this one when present.
- The `agent-config` feature is required (`dependsOn`) and creates the shared
  `AGENT_CONFIG_DIR` used for config symlinks.
- `curl` is required; the feature installs it via apt if missing.

## Post-install

Once installed, run `herdr` in the terminal to start orchestrating agents.
Run `herdr --help` to see the available subcommands.
