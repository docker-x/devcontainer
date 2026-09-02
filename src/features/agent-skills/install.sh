#!/usr/bin/env bash
set -e

# Agent Skills — installs agent skills globally using `npx skills add -g`.
#
# This feature is GitHub-agnostic: it delegates to the `skills` CLI
# (vercel-labs/skills), which uses `git clone` under the hood with `gh` as
# an auth fallback for private repos. The feature does NOT call `gh skill`
# directly — that created a separate lock file that `npx skills update`
# could not read.
#
# What this feature does:
#   1. Build-time: attempts to install PUBLIC skills to a system-wide store
#      as a fallback (no auth needed).
#   2. Writes /usr/local/bin/agent-skills-sync — a runtime script that:
#      a. Runs `npx skills add <repo> -g -y` for each configured package
#      b. Creates per-agent symlinks so each agent finds skills in its
#         expected directory
#   3. Does NOT install a profile.d hook — the sync script is a utility.
#      Consumers should call it from postStartCommand (once per container
#      start), NOT from a per-shell profile.d hook that fires on every login.
#
# The runtime script creates a proper `~/.agents/.skill-lock.json` (v3 format)
# that `npx skills update -g` reads natively.
#
# Requirements (ensured by the devcontainer, not this feature):
#   - `gh` authed on the PVC (for private repos) — npx skills uses it as
#     a git auth fallback via `gh repo clone`
#   - `node` / `npx` available (via the node feature)

AGENTS="${AGENTS:-*}"

# SKILLS is a comma-separated string
SKILLS_STR="${SKILLS:-}"
IFS=',' read -ra SKILLS <<< "${SKILLS_STR}"

REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-vscode}}"
HOME_DIR="${_REMOTE_USER_HOME:-$(getent passwd "$REMOTE_USER" 2>/dev/null | cut -d: -f6)}"
HOME_DIR="${HOME_DIR:-/home/${REMOTE_USER}}"

# System-wide fallback store (for public skills, outside PVC)
SKILLS_STORE="/usr/local/share/agent-skills"

echo "agent-skills: skills=${SKILLS[*]}"
echo "agent-skills: agents=${AGENTS}"

# ---------------------------------------------------------------------------
# Build-time: install PUBLIC skills to system-wide store (fallback)
# npx skills uses git clone — public repos work without auth.
# If GH_TOKEN is set in the environment, git picks it up automatically.
# ---------------------------------------------------------------------------
mkdir -p "$SKILLS_STORE"
chown "${REMOTE_USER}:${REMOTE_USER}" "$SKILLS_STORE" 2>/dev/null || true

# npx skills add -g always installs to $HOME/.agents/skills — no --dir flag.
# To install to the system store (outside PVC), use a temporary HOME.
BUILD_HOME="${SKILLS_STORE}/.build-home"
mkdir -p "$BUILD_HOME"
chown "${REMOTE_USER}:${REMOTE_USER}" "$BUILD_HOME" 2>/dev/null || true

if [[ ${#SKILLS[@]} -gt 0 ]]; then
  for pkg in "${SKILLS[@]}"; do
    pkg=$(echo "${pkg}" | xargs)
    [[ -z "${pkg}" ]] && continue
    echo "agent-skills: attempting build-time install of ${pkg} (public only)"
    # Run npx skills with HOME pointed at the build home so it writes there.
    # --copy so the store has real files (not symlinks into a user home).
    if [[ "$REMOTE_USER" == "root" ]]; then
      env HOME="$BUILD_HOME" npx -y skills add "${pkg}" -g -a devin --copy -y 2>&1 || {
        echo "agent-skills: build-time install failed for ${pkg} (likely private — will retry at runtime)"
      }
    else
      # Escape variables to prevent command injection via pkg names with
      # shell metacharacters. printf %q produces a safely-quoted string.
      escaped_home=$(printf '%q' "$BUILD_HOME")
      escaped_pkg=$(printf '%q' "$pkg")
      su -s /bin/bash "$REMOTE_USER" -c "export HOME=${escaped_home}; npx -y skills add ${escaped_pkg} -g -a devin --copy -y" 2>&1 || {
        echo "agent-skills: build-time install failed for ${pkg} (likely private — will retry at runtime)"
      }
    fi
  done
fi

# Move installed skills from build home to the system store root
if [[ -d "${BUILD_HOME}/.agents/skills" ]]; then
  if cp -r "${BUILD_HOME}/.agents/skills/." "${SKILLS_STORE}/" 2>/dev/null; then
    rm -rf "$BUILD_HOME"
  else
    echo "agent-skills: warning: copy from build home failed, keeping build home for inspection"
  fi
else
  rm -rf "$BUILD_HOME"
fi

SKILL_COUNT=$(find "${SKILLS_STORE}" -maxdepth 2 -name "SKILL.md" 2>/dev/null | wc -l)
echo "agent-skills: ${SKILL_COUNT} public skills in system store"

# Clean up any gh auth state that might have been set by env — don't bake tokens
rm -f /root/.config/gh/hosts.yml 2>/dev/null || true
rm -f "${HOME_DIR}/.config/gh/hosts.yml" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Known agents → skills directory mapping
# Mirrors the agents.ts registry in vercel-labs/skills.
# ---------------------------------------------------------------------------
KNOWN_AGENTS=(
  "devin:.config/devin/skills"
  "claude-code:.claude/skills"
  "github-copilot:.copilot/skills"
  "codex:.codex/skills"
  "cursor:.cursor/skills"
  "opencode:.opencode/skills"
  "gemini-cli:.gemini/skills"
  "goose:.goose/skills"
  "windsurf:.codeium/windsurf/skills"
  "kilo:.kilo/skills"
)

# Build agent symlink list
if [[ "${AGENTS}" == "*" ]]; then
  AGENT_SYMLINKS=("${KNOWN_AGENTS[@]}")
else
  AGENT_SYMLINKS=()
  IFS=',' read -ra AGENT_LIST <<< "${AGENTS}"
  for agent in "${AGENT_LIST[@]}"; do
    agent=$(echo "${agent}" | xargs)
    for known in "${KNOWN_AGENTS[@]}"; do
      known_name="${known%%:*}"
      if [[ "${known_name}" == "${agent}" ]]; then
        AGENT_SYMLINKS+=("$known")
      fi
    done
  done
fi

# ---------------------------------------------------------------------------
# Write runtime sync script: /usr/local/bin/agent-skills-sync
# Uses npx skills add -g so the lock file is compatible with npx skills update
# ---------------------------------------------------------------------------
SKILLS_STRING=""
for pkg in "${SKILLS[@]}"; do
  pkg=$(echo "${pkg}" | xargs)
  [[ -z "$pkg" ]] && continue
  SKILLS_STRING+=" ${pkg}"
done

# Build the agent symlink calls
AGENT_LINK_CALLS=""
for entry in "${AGENT_SYMLINKS[@]}"; do
  dir="${entry#*:}"
  AGENT_LINK_CALLS+="  _agent_skills_link \"$dir\";"$'\n'
done

cat > /usr/local/bin/agent-skills-sync << SYNC_EOF
#!/bin/sh
# Agent Skills sync — call from postStartCommand (NOT from profile.d):
#   1. Install skills from GitHub repos using npx skills add -g
#      (uses git clone with gh auth fallback for private repos)
#   2. Create per-agent symlinks so each agent finds skills in its expected dir
#
# Creates a proper ~/.agents/.skill-lock.json (v3 format) that
# \`npx skills update -g\` reads natively.
#
# Idempotent: skips install if lock file already has skill entries.
# Fallback (no gh auth): links to system store but does NOT install,
# so later runs with auth can still install real skills.

AGENT_SKILLS_STORE="/usr/local/share/agent-skills"
SKILLS_REPOS="${SKILLS_STRING# }"
HOME_FALLBACK="${HOME_DIR}"
LOCK_VERSION="3"

# Fix HOME for OpenShift restricted SCC (sets HOME=/)
_H="\${HOME:-\$HOME_FALLBACK}"
[ "\$_H" = "/" ] && _H="\$HOME_FALLBACK"
export HOME="\$_H"

AGENTS_DIR="\$_H/.agents"
SKILLS_DIR="\$AGENTS_DIR/skills"
LOCK_FILE="\$AGENTS_DIR/.skill-lock.json"

# Helper: check if a directory contains actual SKILL.md files
_has_skills() {
  [ -d "\$1" ] && [ -n "\$(find "\$1" -maxdepth 2 -name 'SKILL.md' 2>/dev/null | head -1)" ]
}

# Helper: count SKILL.md files in a directory
_count_skills() {
  if [ -d "\$1" ]; then
    find "\$1" -maxdepth 2 -name 'SKILL.md' 2>/dev/null | wc -l
  else
    echo 0
  fi
}

# Helper: check if the npx skills lock file has real entries (v3 format)
# and contains every configured repository.
_lock_valid() {
  [ -f "\$LOCK_FILE" ] || return 1
  # Old feature wrote just "2" — not valid for npx skills
  grep -q '"version"' "\$LOCK_FILE" 2>/dev/null || return 1
  # Verify the lock file version is actually 3
  grep -q '"version"[[:space:]]*:[[:space:]]*3' "\$LOCK_FILE" 2>/dev/null || return 1
  _count=\$(grep -c '"sourceType"' "\$LOCK_FILE" 2>/dev/null || echo 0)
  [ "\$_count" -gt 0 ] || return 1
  # Verify every configured repo is present in the lock file.
  # If a new repo was added to SKILLS_REPOS after a previous install,
  # the lock is incomplete and we must re-run the install loop.
  # Normalize the configured source to match what npx skills stores
  # in the v3 lock file (the "source" field):
  #   - owner/repo           → owner/repo
  #   - owner/repo@skill     → owner/repo (strip @skill-name)
  #   - https://github.com/owner/repo[.git] → owner/repo
  #   - git@github.com:owner/repo.git       → owner/repo
  for _repo in \$SKILLS_REPOS; do
    _canonical="\$_repo"
    # Strip @skill-name suffix (but not @host in SSH URLs)
    case "\$_canonical" in
      git@*|ssh://*) ;;  # SSH URL — don't strip @host
      *) _canonical=\${_canonical%@*} ;;
    esac
    # Normalize SSH: git@github.com:owner/repo.git → owner/repo
    case "\$_canonical" in
      git@*:*) _canonical=\${_canonical#git@*:}; _canonical=\${_canonical%.git} ;;
    esac
    # Normalize HTTPS: https://github.com/owner/repo[.git] → owner/repo
    case "\$_canonical" in
      https://github.com/*|http://github.com/*)
        _canonical=\${_canonical#https://github.com/}
        _canonical=\${_canonical#http://github.com/}
        _canonical=\${_canonical%.git}
        ;;
    esac
    grep -Fq "\"source\": \"\$_canonical\"" "\$LOCK_FILE" 2>/dev/null || return 1
  done
  return 0
}

# --- 1. Remove stale lock from old gh-based feature ---
if [ -f "\$LOCK_FILE" ]; then
  if ! grep -q '"version"' "\$LOCK_FILE" 2>/dev/null; then
    echo "agent-skills: removing stale lock from gh-based feature"
    rm -f "\$LOCK_FILE"
  fi
fi

# --- 2. Install skills if not already done ---
if ! _lock_valid; then
  if command -v npx >/dev/null 2>&1; then
    echo "agent-skills: installing skills via npx skills add -g (first run)..."
    mkdir -p "\$AGENTS_DIR" 2>/dev/null || true
    # Remove stale fallback symlink so npx skills installs to real PVC dir
    if [ -L "\$SKILLS_DIR" ]; then
      rm -f "\$SKILLS_DIR"
    fi
    mkdir -p "\$SKILLS_DIR" 2>/dev/null || true
    for repo in \$SKILLS_REPOS; do
      if npx -y skills add "\$repo" -g -a devin -y; then
        echo "agent-skills: installed \$repo"
      else
        echo "agent-skills: failed to install \$repo (skipping)"
      fi
    done
  else
    echo "agent-skills: npx not ready, skipping install (will retry on next sync)"
  fi
fi

# --- 3. Ensure ~/.agents/skills exists ---
# If no PVC skills dir, link to system store (but only if it has real skills)
# This is a fallback — does NOT create lock file, so later runs with auth can retry
if [ ! -e "\$SKILLS_DIR" ] && _has_skills "\$AGENT_SKILLS_STORE"; then
  mkdir -p "\$AGENTS_DIR" 2>/dev/null || true
  ln -sfn "\$AGENT_SKILLS_STORE" "\$SKILLS_DIR"
fi

# --- 4. Create per-agent symlinks ---
_agent_skills_link() {
  _target="\$_H/\$1"
  _parent="\$(dirname "\$_target")"
  if [ ! -e "\$_target" ]; then
    mkdir -p "\$_parent" 2>/dev/null || true
    # Link to ~/.agents/skills if it has skills, else to system store
    if _has_skills "\$SKILLS_DIR"; then
      ln -sfn "\$SKILLS_DIR" "\$_target"
    elif _has_skills "\$AGENT_SKILLS_STORE"; then
      ln -sfn "\$AGENT_SKILLS_STORE" "\$_target"
    fi
  fi
}

${AGENT_LINK_CALLS}
SYNC_EOF

chmod 0755 /usr/local/bin/agent-skills-sync

# ---------------------------------------------------------------------------
# No profile.d / bash.bashrc hook.
#
# Previously this feature installed /etc/profile.d/agent-skills.sh and a line
# in /etc/bash.bashrc that sourced the sync script on every login shell.
# That meant every new tmux session (which starts a login shell) re-ran the
# sync — spamming the terminal and re-invoking npx skills on each session.
#
# The sync script (/usr/local/bin/agent-skills-sync) is still installed as a
# utility. Consumers should call it from postStartCommand or a similar
# once-per-container-start hook, NOT from a per-shell profile.d hook.
# ---------------------------------------------------------------------------

# Clean up legacy hooks from older versions of this feature (≤1.2.0).
# Without this, upgrading the feature on a persistent filesystem leaves the
# old profile.d script and bash.bashrc line in place, so login shells
# (including tmux sessions) continue re-running the sync.
rm -f /etc/profile.d/agent-skills.sh
if [ -f /etc/bash.bashrc ]; then
  sed -i '/agent-skills\.sh/d' /etc/bash.bashrc
fi

echo "agent-skills: runtime sync script at /usr/local/bin/agent-skills-sync"
echo "agent-skills: done (no profile.d hook — call sync from postStartCommand)"
