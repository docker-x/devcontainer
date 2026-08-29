# Workspace Agent (Devsy/DevPod)

Pre-installs Devsy or DevPod agent binaries at build time. Used as a **fallback** when native agent injection fails — most commonly on OpenShift restricted SCC, where the injected agent process cannot run as root.

## What it does

- **Devsy agent** — Optionally downloads the Devsy agent binary at build time. Detects CPU architecture (`x86_64`/`arm64`) and selects the matching release asset, rejecting unsupported architectures. The binary is installed to three locations for maximum robustness:
  - `/usr/local/bin/devsy` — always on PATH, not affected by PVC home mounts
  - `/home/vscode/.local/bin/devsy` — home-based PATH
  - `/etc/skel/.local/bin/devsy` — repopulated into home on first PVC boot by the openshift-compat entrypoint
- **DevPod agent** — Legacy option, kept for rollback during DevPod→Devsy migration. Downloads the DevPod agent binary to `/home/vscode/.local/bin/devpod`.

Both options are disabled by default — test native injection first, enable this feature only if injection fails.

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `installDevsyAgent` | boolean | `false` | Pre-install the Devsy agent binary |
| `installDevpodAgent` | boolean | `false` | Pre-install the DevPod agent binary (legacy) |
| `devsyVersion` | string | `"v1.16.2"` | Pinned Devsy release version to download |

## Usage

```jsonc
{
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu-24.04",
  "features": {
    "ghcr.io/theplenkov/devcontainer-features/workspace-agent:1": {
      "installDevsyAgent": true,
      "devsyVersion": "v1.16.2"
    }
  }
}
```

## Installs after

This feature installs after `ghcr.io/devcontainers/features/common-utils` to ensure the `vscode` user and home directory exist before installing agent binaries.
