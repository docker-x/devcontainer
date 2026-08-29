#!/usr/bin/env bash
set -e

# Agent Skills — install agent skills globally from multiple GitHub repositories.
#
# Each repo is installed using the best available method:
#   - Repos with a bin/skills.js (e.g. theplenkov-ai/skills) → npx github:owner/repo --home --copy
#   - Repos with SKILL.md files but no bin (e.g. gastownhall/beads, github/gh-stack) → gh skill install
#
# The installer option forces one method for all repos:
#   npx  — use npx for all (will fail gracefully on repos without bin/skills.js)
#   gh   — use gh skill install for all
#   auto — detect per-repo (default)

INSTALLER="${INSTALLER:-auto}"
AGENTS="${AGENTS:-*}"
SCOPE="${SCOPE:-home}"
COPY="${COPY:-true}"

# SKILLS is a comma-separated string (devcontainer features don't support array type)
SKILLS_STR="${SKILLS:-}"
IFS=',' read -ra SKILLS <<< "${SKILLS_STR}"

REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-vscode}}"
HOME_DIR="${_REMOTE_USER_HOME:-$(getent passwd "$REMOTE_USER" 2>/dev/null | cut -d: -f6)}"
HOME_DIR="${HOME_DIR:-/home/${REMOTE_USER}}"

echo "agent-skills: installer=${INSTALLER} scope=${SCOPE} copy=${COPY}"
echo "agent-skills: skills=${SKILLS[*]}"
echo "agent-skills: agents=${AGENTS}"

# SCOPE=project is not meaningful during image build (no project context)
if [[ "${SCOPE}" == "project" ]]; then
  echo "agent-skills: WARNING — SCOPE=project is not meaningful during image build (no project directory). Use SCOPE=home for build-time installs."
  echo "agent-skills: Continuing with SCOPE=home"
  SCOPE="home"
fi

# Run a command as the remote user (for home-scoped installs)
# Uses su without - (login flag) to preserve HOME from the environment
run_as_user() {
  if [[ "$REMOTE_USER" == "root" ]]; then
    env HOME="${HOME_DIR}" "$@"
  else
    # Use su without login flag (-) to avoid resetting HOME.
    # Export HOME explicitly in the command string, then exec the args.
    local cmd_args=()
    for arg in "$@"; do
      cmd_args+=("$(printf '%q' "$arg")")
    done
    local escaped_home
    escaped_home=$(printf '%q' "${HOME_DIR}")
    su -s /bin/bash "$REMOTE_USER" -c "export HOME=${escaped_home}; exec ${cmd_args[*]}"
  fi
}

# Convert copy boolean
if [[ "${COPY}" == "true" ]]; then
  COPY_FLAG="--copy"
else
  COPY_FLAG="--no-copy"
fi

# Determine scope flag
if [[ "${SCOPE}" == "home" ]]; then
  NPX_SCOPE="--global"
  GH_SCOPE="--scope user"
else
  NPX_SCOPE="--project"
  GH_SCOPE="--scope project"
fi

# Build agent flags for gh skill
if [[ "${AGENTS}" == "*" ]]; then
  GH_AGENT_FLAG="--all"
else
  GH_AGENT_FLAG=""
  IFS=',' read -ra AGENT_LIST <<< "${AGENTS}"
  for agent in "${AGENT_LIST[@]}"; do
    agent=$(echo "${agent}" | xargs)
    GH_AGENT_FLAG="${GH_AGENT_FLAG} --agent ${agent}"
  done
fi

FAILED_COUNT=0
ATTEMPTED_COUNT=0

# Install a repo via npx (works for repos with bin/skills.js wrapper)
install_via_npx() {
  local repo="$1"
  echo "agent-skills: installing ${repo} via npx"
  run_as_user npx "github:${repo}" ${NPX_SCOPE} ${COPY_FLAG} --yes 2>&1 || {
    echo "agent-skills: WARNING — npx install failed for ${repo}, trying gh skill"
    install_via_gh "${repo}"
  }
}

# Install a repo via gh skill (works for any repo with SKILL.md files)
install_via_gh() {
  local repo="$1"
  echo "agent-skills: installing ${repo} via gh skill"
  run_as_user gh skill install "${repo}" ${GH_SCOPE} ${GH_AGENT_FLAG} --force 2>&1 || {
    echo "agent-skills: WARNING — gh skill install failed for ${repo}, continuing"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  }
}

# Auto-detect: try npx first (for repos with bin/skills.js), fall back to gh skill
install_auto() {
  local repo="$1"
  echo "agent-skills: installing ${repo} (auto-detect)"
  # Try npx first — repos with bin/skills.js will work
  if run_as_user npx "github:${repo}" ${NPX_SCOPE} ${COPY_FLAG} --yes 2>&1; then
    echo "agent-skills: ${repo} installed via npx"
  else
    echo "agent-skills: npx failed for ${repo}, falling back to gh skill"
    install_via_gh "${repo}"
  fi
}

# Install each skill package
if [[ ${#SKILLS[@]} -eq 0 ]]; then
  echo "agent-skills: no skills specified, skipping"
  exit 0
fi

for pkg in "${SKILLS[@]}"; do
  pkg=$(echo "${pkg}" | xargs)  # trim whitespace
  if [[ -z "${pkg}" ]]; then
    continue
  fi

  ATTEMPTED_COUNT=$((ATTEMPTED_COUNT + 1))

  case "${INSTALLER}" in
    npx)
      install_via_npx "${pkg}"
      ;;
    gh)
      install_via_gh "${pkg}"
      ;;
    auto)
      install_auto "${pkg}"
      ;;
    *)
      echo "agent-skills: ERROR — unknown installer '${INSTALLER}', use 'npx', 'gh', or 'auto'"
      exit 1
      ;;
  esac
done

# Check if any installs failed
if [[ ${FAILED_COUNT} -gt 0 ]] && [[ ${FAILED_COUNT} -eq ${ATTEMPTED_COUNT} ]]; then
  echo "agent-skills: ERROR — all skill installations failed" >&2
  exit 1
fi

# Determine the skills directory (SCOPE is always "home" at build time)
SKILLS_DIR="${HOME_DIR}/.agents/skills"

# Ensure skills directory is accessible to the remote user
if [[ -d "${SKILLS_DIR}" ]]; then
  chown -R "${REMOTE_USER}:${REMOTE_USER}" "${HOME_DIR}/.agents" 2>/dev/null || true
fi

# Verify installation
SKILL_COUNT=$(find "${SKILLS_DIR}" -maxdepth 1 -type d 2>/dev/null | wc -l)
SKILL_COUNT=$((SKILL_COUNT - 1))  # subtract the directory itself
if [[ ${SKILL_COUNT} -gt 0 ]]; then
  echo "agent-skills: ${SKILL_COUNT} skills installed to ${SKILLS_DIR}/"
else
  echo "agent-skills: WARNING — no skills found in ${SKILLS_DIR}/"
fi

echo "agent-skills: done"
