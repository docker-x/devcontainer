# DevPod Agent (Legacy)

**DevPod is unmaintained.** This feature exists only for rollback during the DevPod→Devsy migration. Do not use in new containers.

## What it does

Downloads the DevPod agent binary to the remote user's `.local/bin/devpod` (default: `/home/vscode/.local/bin/devpod`), `/usr/local/bin/devpod`, and `/etc/skel/.local/bin/devpod`. The multiple locations ensure `command -v devpod` works even when a PVC mounted at the home directory hides image-layer files. Used as a fallback when DevPod's native agent injection fails on OpenShift restricted SCC.

## Usage

```jsonc
{
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu-24.04",
  "features": {
    "ghcr.io/docker-x/devcontainer/devpod:1": {}
  }
}
```

## Installs after

This feature installs after `ghcr.io/devcontainers/features/common-utils` to ensure the `vscode` user and home directory exist before installing the agent binary.
