#!/usr/bin/env bash
set -uo pipefail

# Tests for zatpilot.env-install.sh.
#
# Runs the installer against a sandboxed HOME (twice) and asserts the
# results: links for instructions, skills, agents, and bin; the generated
# hooks JSON; the PATH line; git config wiring; idempotent re-runs; and the
# backup behavior for pre-existing regular files. The sandbox means the test
# never touches the real ~/.copilot or the user's git config.
#
# Platform differences the assertions have to account for:
#   - Windows installs may be symlinks or, when the account cannot create
#     them, junctions and copies. The test mirrors the installer's probe and
#     asserts against the mode the installer will actually pick.
#   - Git for Windows stores drive-letter paths, so config values are
#     compared in the form git writes them, not the POSIX form we passed.
#   - The Windows registration carries a powershell hook entry as well as a
#     bash one, because a bash entry never fires there.
#   - ZATPILOT_SKIP_WINDOWS_PATH keeps a sandboxed run from writing the
#     sandbox bin directory into the real Windows user PATH.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="${REPO_DIR}/zatpilot.env-install.sh"

case "$(uname -s)" in
  Darwin)               PLATFORM=macos ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
  *)                    PLATFORM=linux ;;
esac

FAILS=0
TOTAL=0
pass() { TOTAL=$((TOTAL + 1)); printf '  ok   %s\n' "$1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '  FAIL %s\n' "$1"; }

# Mirror the installer's symlink probe so the assertions expect the same
# mode the installer will choose on this machine.
LINK_MODE=symlink
if [[ "${PLATFORM}" == "windows" ]]; then
  export MSYS=winsymlinks:nativestrict
  PROBE=$(mktemp -d)
  : > "${PROBE}/t"
  if ln -s "${PROBE}/t" "${PROBE}/l" 2>/dev/null && [[ -L "${PROBE}/l" ]]; then
    LINK_MODE=symlink
  else
    LINK_MODE=copy
  fi
  rm -rf "${PROBE}"
fi

# config_path <posix-path>: the form git stores a path in on this platform.
config_path() {
  if [[ "${PLATFORM}" == "windows" ]]; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# is_link <path> [source]: the path is an install link rather than user
# content. A symlink anywhere, or on a copy-mode Windows box a junction
# (directories) or a byte-identical copy (files).
is_link() {
  local p="$1" src="${2:-}"
  [[ -L "${p}" ]] && return 0
  [[ "${LINK_MODE}" == "symlink" ]] && return 1
  if [[ -d "${p}" ]]; then
    local kind
    kind=$(powershell.exe -NoProfile -Command \
      "(Get-Item -LiteralPath '$(cygpath -m "${p}")' -Force).LinkType" 2>/dev/null | tr -d '\r')
    [[ "${kind}" == "Junction" || "${kind}" == "SymbolicLink" ]] && return 0
    return 1
  fi
  [[ -n "${src}" ]] && cmp -s "${p}" "${src}" && return 0
  return 1
}

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
    export ZATPILOT_SKIP_WINDOWS_PATH=1
    unset COPILOT_HOME
    bash "${INSTALLER}"
  ) >/dev/null 2>&1
}

COPILOT_DIR="${SANDBOX}/.copilot"
if [[ "${PLATFORM}" == "macos" ]]; then
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
src="${REPO_DIR}/copilot/global-copilot-instructions.md"
if [[ "${LINK_MODE}" == "symlink" ]]; then
  if [[ -L "${t}" && "$(readlink "${t}")" == "${src}" ]]; then
    pass "instructions symlink points into the repo"
  else
    fail "instructions symlink wrong or missing: $(readlink "${t}" 2>/dev/null || echo none)"
  fi
else
  if is_link "${t}" "${src}"; then
    pass "instructions installed as a copy of the repo file"
  else
    fail "instructions copy missing or divergent"
  fi
fi

skill_count=0
for s in spec pr codereview security tester architect; do
  if is_link "${COPILOT_DIR}/skills/${s}" && [[ -f "${COPILOT_DIR}/skills/${s}/SKILL.md" ]]; then
    skill_count=$((skill_count + 1))
  fi
done
if [[ "${skill_count}" -eq 6 ]]; then pass "six skill links resolve to SKILL.md"; else fail "expected 6 skill links, got ${skill_count}"; fi

agent_count=0
for a in codereview codefix security tester architect; do
  if is_link "${COPILOT_DIR}/agents/${a}.agent.md" "${REPO_DIR}/copilot/agents/${a}.agent.md" \
     && [[ -f "${COPILOT_DIR}/agents/${a}.agent.md" ]]; then
    agent_count=$((agent_count + 1))
  fi
done
if [[ "${agent_count}" -eq 5 ]]; then pass "five agent links resolve"; else fail "expected 5 agent links, got ${agent_count}"; fi

bin_count=0
for b in codereview-marker codereview-skip spec-backlog-apply; do
  if is_link "${COPILOT_DIR}/bin/${b}" "${REPO_DIR}/bin/${b}" && [[ -x "${COPILOT_DIR}/bin/${b}" ]]; then
    bin_count=$((bin_count + 1))
  fi
done
if [[ "${bin_count}" -eq 3 ]]; then pass "three bin links resolve and are executable"; else fail "expected 3 bin links, got ${bin_count}"; fi

# Windows: PowerShell cannot run an extensionless bash script, so every
# helper needs a .cmd shim that re-enters bash. A missing shim means the
# skills' bare-name invocations fail in the live CLI.
if [[ "${PLATFORM}" == "windows" ]]; then
  shim_count=0
  for b in codereview-marker codereview-skip spec-backlog-apply; do
    shim="${COPILOT_DIR}/bin/${b}.cmd"
    if [[ -f "${shim}" ]] && grep -qF "${b}" "${shim}" && grep -qiF "bash" "${shim}"; then
      shim_count=$((shim_count + 1))
    fi
  done
  if [[ "${shim_count}" -eq 3 ]]; then pass "three .cmd shims generated for PowerShell"; else fail "expected 3 .cmd shims, got ${shim_count}"; fi

  # -U keeps grep in binary mode; MSYS grep strips CR in text mode and the
  # assertion would then fail on a correctly generated shim.
  if grep -qU $'\r' "${COPILOT_DIR}/bin/codereview-marker.cmd" 2>/dev/null; then
    pass "shims are CRLF (cmd.exe format)"
  else
    fail "shims are not CRLF"
  fi
fi

HOOKS_JSON="${COPILOT_DIR}/hooks/zatpilot-env.json"
if [[ -f "${HOOKS_JSON}" ]] && jq -e '.version == 1 and (.hooks.preToolUse | length) == 1' "${HOOKS_JSON}" >/dev/null 2>&1; then
  pass "hooks JSON exists with one preToolUse entry"
else
  fail "hooks JSON missing or malformed"
fi
# The registered path is absolute in the platform's own form: POSIX on
# macOS and Linux, drive-letter on Windows (MSYS hands native programs the
# converted form, and the installer converts explicitly so the value does
# not depend on that).
hook_path=$(jq -r '.hooks.preToolUse[0].bash' "${HOOKS_JSON}" 2>/dev/null)
want_hook=$(config_path "${REPO_DIR}/hooks/pre-push-codereview.sh")
if [[ "${hook_path}" == "${want_hook}" && -x "${hook_path}" ]]; then
  pass "hook path is absolute and points at the repo script"
else
  fail "hook path wrong: ${hook_path} (wanted ${want_hook})"
fi
hook_timeout=$(jq -r '.hooks.preToolUse[0].timeoutSec' "${HOOKS_JSON}" 2>/dev/null)
if [[ "${hook_timeout}" == "30" ]]; then pass "hook timeoutSec is 30"; else fail "hook timeoutSec: ${hook_timeout}"; fi

# A bash hook entry never fires on Windows, so the Windows registration has
# to carry a powershell entry that re-enters bash with the same script.
# Getting this wrong disables the gate silently.
ps_entry=$(jq -r '.hooks.preToolUse[0].powershell // ""' "${HOOKS_JSON}" 2>/dev/null)
if [[ "${PLATFORM}" == "windows" ]]; then
  if [[ "${ps_entry}" == *bash.exe* && "${ps_entry}" == *pre-push-codereview.sh* ]]; then
    pass "powershell hook entry re-enters bash with the gate script"
  else
    fail "powershell hook entry wrong or missing: ${ps_entry}"
  fi
else
  if [[ -z "${ps_entry}" ]]; then
    pass "no powershell hook entry on a Unix platform"
  else
    fail "unexpected powershell hook entry: ${ps_entry}"
  fi
fi

path_lines=$(grep -cF "${COPILOT_DIR}/bin" "${RC_FILE}" 2>/dev/null || true)
if [[ "${path_lines}" -eq 1 ]]; then pass "PATH line present exactly once in $(basename "${RC_FILE}")"; else fail "PATH line count: ${path_lines}"; fi

exc=$(GIT_CONFIG_GLOBAL="${SANDBOX}/.gitconfig" git config --global core.excludesfile 2>/dev/null)
if [[ "${exc}" == "$(config_path "${REPO_DIR}/gitconfig/ignore-global")" ]]; then pass "excludesfile wired"; else fail "excludesfile: ${exc}"; fi
inc_count=$(GIT_CONFIG_GLOBAL="${SANDBOX}/.gitconfig" git config --global --get-all include.path 2>/dev/null | grep -cF "$(config_path "${REPO_DIR}/gitconfig/aliases.gitconfig")" || true)
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

inc_count=$(GIT_CONFIG_GLOBAL="${SANDBOX}/.gitconfig" git config --global --get-all include.path 2>/dev/null | grep -cF "$(config_path "${REPO_DIR}/gitconfig/aliases.gitconfig")" || true)
if [[ "${inc_count}" -eq 1 ]]; then pass "include.path still added once"; else fail "include.path count after re-run: ${inc_count}"; fi

bak_count=$(find "${COPILOT_DIR}" -name '*.bak' 2>/dev/null | wc -l)
if [[ "${bak_count}" -eq 0 ]]; then pass "no .bak churn on re-run"; else fail "unexpected .bak files: ${bak_count}"; fi

if is_link "${COPILOT_DIR}/copilot-instructions.md" "${REPO_DIR}/copilot/global-copilot-instructions.md"; then
  pass "instructions still an install link after re-run"
else
  fail "instructions not an install link after re-run"
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
  export ZATPILOT_SKIP_WINDOWS_PATH=1
  unset COPILOT_HOME
  bash "${INSTALLER}"
) >/dev/null 2>&1
ec=$?
if [[ "${ec}" -eq 0 ]]; then pass "install over existing files exits 0"; else fail "install over existing files exited ${ec}"; fi

if [[ -f "${SANDBOX2}/.copilot/copilot-instructions.md.bak" ]] \
   && grep -q "user content" "${SANDBOX2}/.copilot/copilot-instructions.md.bak" \
   && is_link "${SANDBOX2}/.copilot/copilot-instructions.md" "${REPO_DIR}/copilot/global-copilot-instructions.md"; then
  pass "regular instructions file backed up then linked"
else
  fail "instructions backup behavior wrong"
fi

if ! is_link "${SANDBOX2}/.copilot/skills/spec" && grep -q "user skill" "${SANDBOX2}/.copilot/skills/spec/SKILL.md"; then
  pass "real skill directory preserved (warn and skip)"
else
  fail "real skill directory was replaced"
fi

if is_link "${SANDBOX2}/.copilot/skills/codereview"; then
  pass "other skills still linked around the skipped one"
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
