# OpenAI Codex CLI

This devcontainer feature installs the [OpenAI Codex CLI](https://github.com/openai/codex),
OpenAI's AI coding agent for terminal-based development.

## Usage

Add the feature to your `devcontainer.json`:

```jsonc
{
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
  "features": {
    "ghcr.io/devcontainers/features/node:latest": {},
    "ghcr.io/docker-x/devcontainer/agent-config:1": {},
    "ghcr.io/docker-x/devcontainer/codex:1": {
      "version": "latest"
    }
  }
}
```

### Options

| Option    | Type   | Default   | Description                                                                          |
| --------- | ------ | --------- | ------------------------------------------------------------------------------------ |
| `version` | string | `latest`  | Version of the `@openai/codex` npm package to install. Use `latest` or a specific published version (e.g. `0.1.0`). |

## What it does

1. Installs the `@openai/codex` npm package globally via `npm install -g`.
2. Copies the `codex` binary to `/usr/local/bin/codex` for system-wide access.
3. Verifies the installation with `codex --version`.
4. Creates a shared config directory under `AGENT_CONFIG_DIR` and symlinks
   `~/.codex` and `~/.config/codex` to it so Codex keeps its config alongside
   other agents.

## Requirements

- Node.js and `npm` must already be installed in the image. The feature
  declares `installsAfter` the official `node` feature, so list that feature
  (or an equivalent Node.js install) before this one.
- The `agent-config` feature is required (`dependsOn`) and creates the shared
  `AGENT_CONFIG_DIR` used for config symlinks.

## Post-install

Once installed, run `codex` in the terminal to start the agent. Run
`codex --help` to see the available subcommands. Set your `OPENAI_API_KEY`
environment variable to authenticate.
