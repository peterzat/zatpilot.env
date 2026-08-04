#!/usr/bin/env bash
set -uo pipefail

# Tests for zatpilot.env-install.sh.
#
# Runs the installer against a sandboxed HOME (twice) and asserts the
# results: symlinks for instructions, skills, agents, and bin; the
# generated hooks JSON; the PATH line; git config wiring; idempotent
# re-runs; and the backup behavior for pre-existing regular files.
# The sandbox means the test never touches the real ~/.copilot or the
# user's git config.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="${REPO_DIR}/zatpilot.env-install.sh"

FAILS=0
TOTAL=0
pass() { TOTAL=$((TOTAL + 1)); printf '  ok   %s\n' "$1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '  FAIL %s\n' "$1"; }

SANDBOX=$(mktemp -d)
cleanup() { rm -rf "${SANDBOX}"; }
trap cleanup EXIT

# Run the installer inside the sandbox. Identity comes from env so the
# prompt loop never fires. GIT_CONFIG_GLOBAL pins git's global config
# inside the sandbox regardless of the caller's environment.
run_installer() {
  (
    export HOME="${SANDBOX}"
    export GIT_CONFIG_GLOBAL="${SANDBOX}/.gitconfig"
    export GIT_NAME="Test User"
    export GIT_EMAIL="test@test.invalid"
    unset COPILOT_HOME
    bash "${INSTALLER}"
  ) >/dev/null 2>&1
}

COPILOT_DIR="${SANDBOX}/.copilot"
if [[ "$(uname)" == "Darwin" ]]; then
  RC_FILE="${SANDBOX}/.zshrc"
else
  RC_FILE="${SANDBOX}/.bashrc"
fi

# ============================================================
echo "==> First install run"
# ============================================================

run_installer ; ec=$?
if [[ "${ec}" -eq 0 ]]; then pass "installer exits 0"; else fail "installer exited ${ec}"; fi

t="${COPILOT_DIR}/copilot-instructions.md"
if [[ -L "${t}" && "$(readlink "${t}")" == "${REPO_DIR}/copilot/global-copilot-instructions.md" ]]; then
  pass "instructions symlink points into the repo"
else
  fail "instructions symlink wrong or missing: $(readlink "${t}" 2>/dev/null || echo none)"
fi

skill_count=0
for s in spec pr codereview security tester architect; do
  if [[ -L "${COPILOT_DIR}/skills/${s}" && -f "${COPILOT_DIR}/skills/${s}/SKILL.md" ]]; then
    skill_count=$((skill_count + 1))
  fi
done
if [[ "${skill_count}" -eq 6 ]]; then pass "six skill symlinks resolve to SKILL.md"; else fail "expected 6 skill symlinks, got ${skill_count}"; fi

agent_count=0
for a in codereview codefix security tester architect; do
  if [[ -L "${COPILOT_DIR}/agents/${a}.agent.md" && -f "${COPILOT_DIR}/agents/${a}.agent.md" ]]; then
    agent_count=$((agent_count + 1))
  fi
done
if [[ "${agent_count}" -eq 5 ]]; then pass "five agent symlinks resolve"; else fail "expected 5 agent symlinks, got ${agent_count}"; fi

bin_count=0
for b in codereview-marker codereview-skip spec-backlog-apply.sh; do
  if [[ -L "${COPILOT_DIR}/bin/${b}" && -x "${COPILOT_DIR}/bin/${b}" ]]; then
    bin_count=$((bin_count + 1))
  fi
done
if [[ "${bin_count}" -eq 3 ]]; then pass "three bin symlinks resolve and are executable"; else fail "expected 3 bin symlinks, got ${bin_count}"; fi

HOOKS_JSON="${COPILOT_DIR}/hooks/zatpilot-env.json"
if [[ -f "${HOOKS_JSON}" ]] && jq -e '.version == 1 and (.hooks.preToolUse | length) == 1' "${HOOKS_JSON}" >/dev/null 2>&1; then
  pass "hooks JSON exists with one preToolUse entry"
else
  fail "hooks JSON missing or malformed"
fi
hook_path=$(jq -r '.hooks.preToolUse[0].bash' "${HOOKS_JSON}" 2>/dev/null)
if [[ "${hook_path}" == /* && -x "${hook_path}" && "${hook_path}" == "${REPO_DIR}/hooks/pre-push-codereview.sh" ]]; then
  pass "hook path is absolute and points at the repo script"
else
  fail "hook path wrong: ${hook_path}"
fi
hook_timeout=$(jq -r '.hooks.preToolUse[0].timeoutSec' "${HOOKS_JSON}" 2>/dev/null)
if [[ "${hook_timeout}" == "30" ]]; then pass "hook timeoutSec is 30"; else fail "hook timeoutSec: ${hook_timeout}"; fi

path_lines=$(grep -cF "${COPILOT_DIR}/bin" "${RC_FILE}" 2>/dev/null || true)
if [[ "${path_lines}" -eq 1 ]]; then pass "PATH line present exactly once in $(basename "${RC_FILE}")"; else fail "PATH line count: ${path_lines}"; fi

exc=$(GIT_CONFIG_GLOBAL="${SANDBOX}/.gitconfig" git config --global core.excludesfile 2>/dev/null)
if [[ "${exc}" == "${REPO_DIR}/gitconfig/ignore-global" ]]; then pass "excludesfile wired"; else fail "excludesfile: ${exc}"; fi
inc_count=$(GIT_CONFIG_GLOBAL="${SANDBOX}/.gitconfig" git config --global --get-all include.path 2>/dev/null | grep -cF "${REPO_DIR}/gitconfig/aliases.gitconfig" || true)
if [[ "${inc_count}" -eq 1 ]]; then pass "aliases include.path added once"; else fail "include.path count: ${inc_count}"; fi
name=$(GIT_CONFIG_GLOBAL="${SANDBOX}/.gitconfig" git config --global user.name 2>/dev/null)
if [[ "${name}" == "Test User" ]]; then pass "git identity set from env without prompting"; else fail "user.name: ${name}"; fi

# The installer must not create or modify CLI-owned state files.
cli_owned=0
for f in settings.json config.json permissions-config.json; do
  [[ -e "${COPILOT_DIR}/${f}" ]] && cli_owned=$((cli_owned + 1))
done
if [[ "${cli_owned}" -eq 0 ]]; then pass "no CLI-owned state files touched"; else fail "installer created CLI-owned state files"; fi

# ============================================================
echo ""
echo "==> Second run is idempotent"
# ============================================================

run_installer ; ec=$?
if [[ "${ec}" -eq 0 ]]; then pass "re-run exits 0"; else fail "re-run exited ${ec}"; fi

path_lines=$(grep -cF "${COPILOT_DIR}/bin" "${RC_FILE}" 2>/dev/null || true)
if [[ "${path_lines}" -eq 1 ]]; then pass "PATH line still exactly once"; else fail "PATH line count after re-run: ${path_lines}"; fi

inc_count=$(GIT_CONFIG_GLOBAL="${SANDBOX}/.gitconfig" git config --global --get-all include.path 2>/dev/null | grep -cF "${REPO_DIR}/gitconfig/aliases.gitconfig" || true)
if [[ "${inc_count}" -eq 1 ]]; then pass "include.path still added once"; else fail "include.path count after re-run: ${inc_count}"; fi

bak_count=$(find "${COPILOT_DIR}" -name '*.bak' 2>/dev/null | wc -l)
if [[ "${bak_count}" -eq 0 ]]; then pass "no .bak churn on re-run"; else fail "unexpected .bak files: ${bak_count}"; fi

if [[ -L "${COPILOT_DIR}/copilot-instructions.md" ]]; then
  pass "instructions still a symlink after re-run"
else
  fail "instructions not a symlink after re-run"
fi

# ============================================================
echo ""
echo "==> Pre-existing regular files: backup and skip behaviors"
# ============================================================

SANDBOX2=$(mktemp -d)
mkdir -p "${SANDBOX2}/.copilot/skills/spec"
echo "user content" > "${SANDBOX2}/.copilot/copilot-instructions.md"
echo "user skill" > "${SANDBOX2}/.copilot/skills/spec/SKILL.md"
(
  export HOME="${SANDBOX2}"
  export GIT_CONFIG_GLOBAL="${SANDBOX2}/.gitconfig"
  export GIT_NAME="Test User"
  export GIT_EMAIL="test@test.invalid"
  unset COPILOT_HOME
  bash "${INSTALLER}"
) >/dev/null 2>&1
ec=$?
if [[ "${ec}" -eq 0 ]]; then pass "install over existing files exits 0"; else fail "install over existing files exited ${ec}"; fi

if [[ -f "${SANDBOX2}/.copilot/copilot-instructions.md.bak" ]] \
   && grep -q "user content" "${SANDBOX2}/.copilot/copilot-instructions.md.bak" \
   && [[ -L "${SANDBOX2}/.copilot/copilot-instructions.md" ]]; then
  pass "regular instructions file backed up then symlinked"
else
  fail "instructions backup behavior wrong"
fi

if [[ ! -L "${SANDBOX2}/.copilot/skills/spec" ]] && grep -q "user skill" "${SANDBOX2}/.copilot/skills/spec/SKILL.md"; then
  pass "real skill directory preserved (warn and skip)"
else
  fail "real skill directory was replaced"
fi

if [[ -L "${SANDBOX2}/.copilot/skills/codereview" ]]; then
  pass "other skills still symlinked around the skipped one"
else
  fail "other skills missing"
fi

rm -rf "${SANDBOX2}"

# ============================================================
echo ""
if [[ "${FAILS}" -eq 0 ]]; then
  echo "All ${TOTAL} checks passed."
else
  echo "${FAILS} of ${TOTAL} checks failed."
  exit 1
fi
