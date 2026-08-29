# OpenShift Compatibility

Makes a devcontainer image compatible with OpenShift's **restricted Security Context Constraint (SCC)**.

OpenShift restricted SCC assigns a random UID/GID at runtime, blocks privilege escalation, and disallows real `sudo`. This feature prepares the image so it works correctly under those constraints.

## What it does

- **SSH server** — Installs and configures `openssh-server` to listen on a configurable port (default `2222`) with key-based auth only.
- **Authorized keys** — Uses `/etc/ssh/authorized_keys` (writable by root group) instead of `~/.ssh/authorized_keys`, because home directory ownership is fluid under random UIDs.
- **Host keys** — Generates SSH host keys at build time; the entrypoint regenerates them into `/tmp/ssh` at runtime if needed.
- **`/etc/passwd` & `/etc/group`** — Made group-writable (`chmod g=u`) so the runtime entrypoint can rewrite the `vscode` user's UID/GID to match the OpenShift-assigned random UID.
- **Home directory** — `/home/vscode` is made group-writable by group 0 (`chgrp -R 0`, `chmod -R g+rwX`) so the random-UID user can read and write.
- **Fake sudo** — A wrapper at `/usr/local/bin/sudo` handles query flags (`-n`, `-nl`, `-v`, `-l`) and passes through real commands. Needed because OpenShift restricted SCC blocks real `sudo`, but many install scripts check for it.
- **Entrypoint** — Installs `/usr/local/bin/entrypoint.sh` which handles UID/GID adjustment, SSH host key generation, authorized keys setup, persistent state symlinks, Paseo daemon startup (if present), and SSH server startup.

## What it does NOT do

Agent binary pre-install (Devsy/DevPod) is handled by the separate **devsy** and **devpod** features. This keeps OpenShift compatibility concerns (SCC, UID, SSH) separate from orchestrator-specific concerns (which agent binary to install).

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `sshPort` | string | `"2222"` | Port for the SSH server to listen on |

## Usage

```jsonc
{
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu-24.04",
  "features": {
    "ghcr.io/theplenkov/devcontainer-features/openshift-compat:1": {
      "sshPort": "2222"
    }
  }
}
```

## Installs after

This feature installs after `ghcr.io/devcontainers/features/common-utils` to ensure the `vscode` user and home directory exist before applying OpenShift compatibility fixes.
