#!/usr/bin/env bash
set -euo pipefail

# Wire this repo's config into the live system: git identity and aliases,
# global instructions, skills, agents, helper scripts, and the pre-push
# gate hook. Idempotent; re-run after pulling changes.
#
# Targets ${COPILOT_HOME:-~/.copilot}. This script never touches the CLI's
# own state or configuration files (settings.json, config.json,
# permissions-config.json); it only adds instruction, skill, agent, bin,
# and hook entries that the CLI discovers by path.

if [[ "${EUID}" -eq 0 ]]; then
  echo "Run this as your normal user, not root."
  exit 1
fi

if ! command -v jq &>/dev/null; then
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "ERROR: jq is required. Install with: brew install jq"
  else
    echo "ERROR: jq is required. Install with: sudo apt install jq"
  fi
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COPILOT_DIR="${COPILOT_HOME:-${HOME}/.copilot}"

echo "==> zatpilot.env-install: wiring repo config into the live system"
echo "    Repo:   ${REPO_DIR}"
echo "    Target: ${COPILOT_DIR}"

# --- git config ---
echo "==> Configuring git globals"
git config --global init.defaultBranch main

GIT_NAME="${GIT_NAME:-$(git config --global user.name 2>/dev/null || true)}"
while [[ -z "${GIT_NAME}" ]]; do
  read -rp "Git user.name: " GIT_NAME
done
git config --global user.name "${GIT_NAME}"

GIT_EMAIL="${GIT_EMAIL:-$(git config --global user.email 2>/dev/null || true)}"
while [[ -z "${GIT_EMAIL}" ]]; do
  read -rp "Git user.email: " GIT_EMAIL
done
git config --global user.email "${GIT_EMAIL}"
git config --global core.excludesfile "${REPO_DIR}/gitconfig/ignore-global"

# include.path supports multiple values; only add if not already present
if ! git config --global --get-all include.path 2>/dev/null | grep -qF "${REPO_DIR}/gitconfig/aliases.gitconfig"; then
  git config --global --add include.path "${REPO_DIR}/gitconfig/aliases.gitconfig"
fi

# --- global instructions symlink ---
INSTRUCTIONS_TARGET="${COPILOT_DIR}/copilot-instructions.md"
echo "==> Symlinking ${INSTRUCTIONS_TARGET} -> ${REPO_DIR}/copilot/global-copilot-instructions.md"
mkdir -p "${COPILOT_DIR}"
if [[ -L "${INSTRUCTIONS_TARGET}" ]]; then
  rm "${INSTRUCTIONS_TARGET}"
elif [[ -f "${INSTRUCTIONS_TARGET}" ]]; then
  echo "    WARNING: ${INSTRUCTIONS_TARGET} exists and is not a symlink; moving to copilot-instructions.md.bak"
  mv "${INSTRUCTIONS_TARGET}" "${INSTRUCTIONS_TARGET}.bak"
fi
ln -s "${REPO_DIR}/copilot/global-copilot-instructions.md" "${INSTRUCTIONS_TARGET}"

# --- skills symlinks ---
echo "==> Symlinking skills into ${COPILOT_DIR}/skills/"
mkdir -p "${COPILOT_DIR}/skills"

for skill_dir in "${REPO_DIR}/copilot/skills"/*/; do
  skill_name="$(basename "${skill_dir}")"
  target="${COPILOT_DIR}/skills/${skill_name}"

  if [[ -L "${target}" ]]; then
    rm "${target}"
  elif [[ -d "${target}" ]]; then
    echo "    WARNING: ${target} exists and is not a symlink; skipping ${skill_name}"
    continue
  fi

  ln -s "${skill_dir}" "${target}"
  echo "    ${skill_name} -> ${skill_dir}"
done

# --- agents symlinks ---
echo "==> Symlinking agents into ${COPILOT_DIR}/agents/"
mkdir -p "${COPILOT_DIR}/agents"

for agent_file in "${REPO_DIR}/copilot/agents"/*.agent.md; do
  agent_name="$(basename "${agent_file}")"
  target="${COPILOT_DIR}/agents/${agent_name}"

  if [[ -L "${target}" ]]; then
    rm "${target}"
  elif [[ -f "${target}" ]]; then
    echo "    WARNING: ${target} exists and is not a symlink; skipping ${agent_name}"
    continue
  fi

  ln -s "${agent_file}" "${target}"
  echo "    ${agent_name} -> ${agent_file}"
done

# --- helper scripts ---
echo "==> Symlinking helper scripts into ${COPILOT_DIR}/bin/"
BIN_DIR="${COPILOT_DIR}/bin"
mkdir -p "${BIN_DIR}"

for script in "${REPO_DIR}/bin"/*; do
  script_name="$(basename "${script}")"
  target="${BIN_DIR}/${script_name}"

  if [[ -L "${target}" ]]; then
    rm "${target}"
  elif [[ -f "${target}" ]]; then
    echo "    WARNING: ${target} exists and is not a symlink; replacing with symlink"
    rm "${target}"
  fi

  ln -s "${script}" "${target}"
  echo "    ${script_name} -> ${script}"
done

# --- PATH entry ---
# The skills and agents invoke codereview-marker, codereview-skip, and
# spec-backlog-apply.sh by bare name, and the user types codereview-skip
# for the push-now bypass. The gate hook itself does NOT depend on PATH
# (it resolves the marker script relative to its own location).
if [[ "$(uname)" == "Darwin" ]]; then
  RC_FILE="${HOME}/.zshrc"
else
  RC_FILE="${HOME}/.bashrc"
fi
PATH_LINE="export PATH=\"${BIN_DIR}:\$PATH\"  # zatpilot.env"
if [[ ! -f "${RC_FILE}" ]] || ! grep -qF "${PATH_LINE}" "${RC_FILE}"; then
  printf '\n%s\n' "${PATH_LINE}" >> "${RC_FILE}"
  echo "==> Added ${BIN_DIR} to PATH in ${RC_FILE} (open a new shell to pick it up)"
else
  echo "==> PATH entry already present in ${RC_FILE}"
fi

# --- pre-push gate hook registration ---
# Written (not symlinked) so the JSON can carry the absolute repo path.
# Regenerated on every run; this file is owned by the installer.
HOOKS_DIR="${COPILOT_DIR}/hooks"
HOOKS_JSON="${HOOKS_DIR}/zatpilot-env.json"
echo "==> Writing ${HOOKS_JSON}"
mkdir -p "${HOOKS_DIR}"
jq -n --arg cmd "${REPO_DIR}/hooks/pre-push-codereview.sh" '{
  version: 1,
  hooks: {
    preToolUse: [
      {
        type: "command",
        bash: $cmd,
        timeoutSec: 30
      }
    ]
  }
}' > "${HOOKS_JSON}"

echo "==> Done"
echo
echo "Verify:"
echo "  git st                                           # alias from gitconfig"
echo "  ls -la ${INSTRUCTIONS_TARGET}                    # symlink into the repo"
echo "  ls -la ${COPILOT_DIR}/skills/                    # six skill symlinks"
echo "  ls -la ${COPILOT_DIR}/agents/                    # five agent symlinks"
echo "  ls -la ${BIN_DIR}/                               # three helper symlinks"
echo "  jq . ${HOOKS_JSON}                               # gate hook registration"
echo "  bash ${REPO_DIR}/tests/run-all.sh                # full test suite"
echo
echo "In the CLI: /skills list should show the six skills, and /agent should"
echo "list the five agents. First run on a new machine: walk docs/mac-validation.md."
