#!/usr/bin/env bash
set -e

# Agent Skills — install agent skills globally from GitHub repositories.
#
# Supports two installers:
#   npx  — uses `npx github:owner/repo --home --copy` (skills CLI)
#   gh   — uses `gh skill install owner/repo --scope user --all` (gh skill)
#
# Multiple skill packages can be specified as a comma-separated list.

INSTALLER="${INSTALLER:-npx}"
SKILLS="${SKILLS:-theplenkov-ai/skills}"
AGENTS="${AGENTS:-*}"
SCOPE="${SCOPE:-home}"
COPY="${COPY:-true}"

REMOTE_USER="${_REMOTE_USER:-${_CONTAINER_USER:-vscode}}"
HOME_DIR="/home/${REMOTE_USER}"

echo "agent-skills: installer=${INSTALLER} scope=${SCOPE} copy=${COPY}"
echo "agent-skills: skills=${SKILLS}"
echo "agent-skills: agents=${AGENTS}"

# Parse comma-separated skills list
IFS=',' read -ra SKILL_PACKAGES <<< "${SKILLS}"

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

# Build agent flags
if [[ "${AGENTS}" == "*" ]]; then
  NPX_AGENTS="--all"
  GH_AGENTS="--all"
else
  # Convert comma list to repeated --agent flags
  NPX_AGENTS=""
  GH_AGENTS=""
  IFS=',' read -ra AGENT_LIST <<< "${AGENTS}"
  for agent in "${AGENT_LIST[@]}"; do
    agent=$(echo "${agent}" | xargs)  # trim whitespace
    NPX_AGENTS="${NPX_AGENTS} --agent ${agent}"
    GH_AGENTS="${GH_AGENTS} --agent ${agent}"
  done
fi

install_via_npx() {
  local repo="$1"
  echo "agent-skills: installing ${repo} via npx skills"
  # npx github:owner/repo --home --copy --yes
  # The skills CLI auto-detects agents and creates symlinks
  if [[ "${AGENTS}" == "*" ]]; then
    npx "github:${repo}" ${NPX_SCOPE} ${COPY_FLAG} --yes 2>&1 || {
      echo "agent-skills: WARNING — npx install failed for ${repo}, continuing"
    }
  else
    npx "github:${repo}" ${NPX_SCOPE} ${COPY_FLAG} ${NPX_AGENTS} --yes 2>&1 || {
      echo "agent-skills: WARNING — npx install failed for ${repo}, continuing"
    }
  fi
}

install_via_gh() {
  local repo="$1"
  echo "agent-skills: installing ${repo} via gh skill"
  # gh skill install owner/repo --all --scope user
  gh skill install "${repo}" --all ${GH_SCOPE} --force 2>&1 || {
    echo "agent-skills: WARNING — gh skill install failed for ${repo}, continuing"
  }
}

# Install each skill package
for pkg in "${SKILL_PACKAGES[@]}"; do
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
    *)
      echo "agent-skills: ERROR — unknown installer '${INSTALLER}', use 'npx' or 'gh'"
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
