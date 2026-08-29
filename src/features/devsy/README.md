# Devsy Agent

Pre-installs the Devsy agent binary at build time. Used as a **fallback** when native agent injection fails — most commonly on OpenShift restricted SCC, where the injected agent process cannot run as root.

## What it does

Downloads the Devsy agent binary at build time. Detects CPU architecture (`x86_64`/`arm64`) and selects the matching release asset, rejecting unsupported architectures. Verifies SHA-256 integrity of the download. The binary is installed to three locations for maximum robustness:

- `/usr/local/bin/devsy` — always on PATH, not affected by PVC home mounts
- `/home/vscode/.local/bin/devsy` — home-based PATH
- `/etc/skel/.local/bin/devsy` — repopulated into home on first PVC boot by the openshift-compat entrypoint

Disabled by default — test native injection first, enable this feature only if injection fails.

The Devsy version is pinned to `v1.16.2` with SHA-256 integrity verification. There are no user-configurable options; upgrading requires updating the pinned version and checksums in `install.sh`.

## Usage

```jsonc
{
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu-24.04",
  "features": {
    "ghcr.io/docker-x/devcontainer/devsy:1": {}
  }
}
```

## Installs after

This feature installs after `ghcr.io/devcontainers/features/common-utils` to ensure the `vscode` user and home directory exist before installing the agent binary.
