# Paseo CLI

This devcontainer feature installs the [Paseo CLI](https://getpaseo.sh), a
local-first AI development environment that bundles a daemon, a web UI, and
agent orchestration into a single command-line tool.

## Usage

Add the feature to your `devcontainer.json`:

```jsonc
{
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
  "features": {
    "ghcr.io/devcontainers/features/node:latest": {},
    "./src/features/paseo": {
      "version": "latest"
    }
  }
}
```

### Options

| Option    | Type   | Default   | Description                                      |
| --------- | ------ | --------- | ------------------------------------------------ |
| `version` | string | `latest`  | Version of the `@getpaseo/cli` npm package to install. Use `latest` or a specific published version (e.g. `1.2.3`). |

## What it does

1. Installs the `@getpaseo/cli` npm package globally via `npm install -g`.
2. Verifies the `paseo` binary is available on `PATH`.
3. Sets `PASEO_HOME` to `~/.paseo` via `/etc/profile.d` and `/etc/environment`
   so the CLI and daemon share state. Persistence across container rebuilds
   requires a PVC-backed home directory (e.g. via the `openshift-compat` feature
   or a devcontainer volume mount on `~/.paseo`).

## Requirements

- Node.js and `npm` must already be installed in the image. The feature
  declares `installsAfter` the official `node` feature, so list that feature
  (or an equivalent Node.js install) before this one.

## Post-install

Once installed, run `paseo` in the terminal to start the daemon and open the
web UI. Run `paseo --help` to see the available subcommands.
