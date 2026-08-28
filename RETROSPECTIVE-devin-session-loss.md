# Retrospective: Devin session data loss due to HOME=/ bug

**Date:** 2026-08-28
**Severity:** High — 6 Devin sessions lost (conversation context only, code was pushed)

## What happened

Devin CLI sessions (salt-jargon, tarry-cloak, laser-wormhole, medieval-buzzard, scarlet-airedale, jealous-yacht) were lost when the OpenShift DevPod pod was recreated after an image rebuild.

## Root cause

OpenShift sets `HOME=/` by default for random-UID containers. The openshift-compat entrypoint used `export HOME="${HOME:-/home/vscode}"` which resolved to `HOME=/` on OpenShift.

With `HOME=/`, Devin CLI wrote session data to `/.local/share/devin/` — the container's **ephemeral filesystem**, NOT the PVC-backed symlink at `/home/vscode/.local/share/devin -> /workspace-state/.devin-data`.

When the pod was recreated (image rebuild for PR #14 which fixed HOME), the ephemeral filesystem was destroyed. The new pod with `HOME=/home/vscode` created a fresh sessions.db on the PVC, but the old sessions were gone.

## Timeline

- Aug 26: PVC created, symlinks set up, but HOME=/ bug present
- Aug 27-28 morning: Devin sessions active via Paseo — writing to ephemeral `/.local/share/devin/`
- Aug 28 ~10:29 UTC: Last session activity
- Aug 28 13:12 UTC: PR #14 merged (HOME=/home/vscode fix)
- Aug 28 ~13:18 UTC: Pod recreated with new image — ephemeral data lost
- Aug 28 ~16:41 UTC: Current pod started — fresh sessions.db on PVC

## What was preserved

- Paseo agent metadata in `/workspace-state/.paseo/agents/` (on PVC)
- Sverka source code (on PVC + GitHub)
- Devin config, GitHub CLI auth (on PVC)

## What was lost

- 6 Devin session transcripts and message histories
- Sessions covered Sverka refactor phases and terraform/Redesign work
- Code changes were committed and pushed — only conversation context lost

## Lessons learned

1. **Verify where data is actually written BEFORE recreating pods.** Check `HOME` env, check actual write paths, don't assume symlinks work if HOME is wrong.
2. **HOME=/ on OpenShift is critical for any tool writing to ~/.** Use `export HOME=/home/vscode` unconditionally, not `${HOME:-/home/vscode}`.
3. **Paseo agent metadata persistence ≠ Devin session persistence.** Paseo stores agent metadata on PVC, but Devin sessions are in Devin's own DB elsewhere.
4. **Always check actual data location before destructive operations.** `du -sh /.local/share/devin/` would have revealed data was in ephemeral storage.
5. **Backup only captured PVC data** — ephemeral data in `/.local/share/devin/` was missed.

## Fix applied

PR #14 (docker-x/devcontainer) — `export HOME="/home/vscode"` unconditionally in entrypoint. Also added to `/etc/environment`.

## Prevention

- HOME=/home/vscode fix is now in the image (merged PR #14)
- Future pod recreations will have Devin writing to PVC-backed path
- Backup CronJob captures `/workspace-state/` (PVC) — now includes Devin sessions
