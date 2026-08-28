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
HOME_DIR="/home/${REMOTE_USER}"

echo "agent-skills: installer=${INSTALLER} scope=${SCOPE} copy=${COPY}"
echo "agent-skills: skills=${SKILLS[*]}"
echo "agent-skills: agents=${AGENTS}"

# Convert copy boolean
if [[ "${COPY}" == "true" ]]; then
  COPY_FLAG="--copy"
else
  COPY_FLAG="--no-copy"
fi

# Determine scope flag
if [[ "${SCOPE}" == "home" ]]; then
  NPX_SCOPE="--home"
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

# Install a repo via npx (works for repos with bin/skills.js wrapper)
install_via_npx() {
  local repo="$1"
  echo "agent-skills: installing ${repo} via npx"
  npx "github:${repo}" ${NPX_SCOPE} ${COPY_FLAG} --yes 2>&1 || {
    echo "agent-skills: WARNING — npx install failed for ${repo}, trying gh skill"
    install_via_gh "${repo}"
  }
}

# Install a repo via gh skill (works for any repo with SKILL.md files)
install_via_gh() {
  local repo="$1"
  echo "agent-skills: installing ${repo} via gh skill"
  gh skill install "${repo}" --all ${GH_SCOPE} ${GH_AGENT_FLAG} --force 2>&1 || {
    echo "agent-skills: WARNING — gh skill install failed for ${repo}, continuing"
  }
}

# Auto-detect: try npx first (for repos with bin/skills.js), fall back to gh skill
install_auto() {
  local repo="$1"
  echo "agent-skills: installing ${repo} (auto-detect)"
  # Try npx first — repos with bin/skills.js will work
  if npx "github:${repo}" ${NPX_SCOPE} ${COPY_FLAG} --yes 2>&1; then
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

# Ensure ~/.agents/skills is accessible to the remote user
if [[ -d "${HOME_DIR}/.agents/skills" ]]; then
  chown -R "${REMOTE_USER}:${REMOTE_USER}" "${HOME_DIR}/.agents" 2>/dev/null || true
fi

# Verify installation
SKILL_COUNT=$(find "${HOME_DIR}/.agents/skills" -maxdepth 1 -type d 2>/dev/null | wc -l)
SKILL_COUNT=$((SKILL_COUNT - 1))  # subtract the directory itself
if [[ ${SKILL_COUNT} -gt 0 ]]; then
  echo "agent-skills: ${SKILL_COUNT} skills installed to ${HOME_DIR}/.agents/skills/"
else
  echo "agent-skills: WARNING — no skills found in ${HOME_DIR}/.agents/skills/"
fi

echo "agent-skills: done"
