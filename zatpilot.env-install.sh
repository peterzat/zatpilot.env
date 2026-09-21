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
#
# Runs on macOS, Linux, and Windows. On Windows it must be run from Git
# Bash (the whole toolchain is bash), and it does four extra things the
# Unix platforms do not need:
#
#   1. Native symlinks. MSYS turns `ln -s` into a silent file COPY unless
#      MSYS=winsymlinks:nativestrict is set and the account may create
#      symlinks (Developer Mode on, or an elevated shell). The script sets
#      the variable, probes the capability, and falls back to junctions
#      for directories and copies for files when the probe fails. Copies
#      are not live: in that mode the installer has to be re-run after
#      every pull. The mode is printed so it is never a surprise.
#   2. A powershell hook entry. Copilot CLI hook commands are
#      platform-exclusive: a `bash` entry never runs on Windows. Without a
#      `powershell` entry the pre-push gate would be silently absent, so
#      the Windows registration carries both.
#   3. .cmd shims for the helper scripts. The CLI's shell tool on Windows
#      is PowerShell, which cannot execute an extensionless bash script.
#      Each helper gets a generated <name>.cmd beside it that re-enters
#      bash, so skills and agents keep invoking helpers by bare name.
#   4. PATH in the Windows user environment, not only in a shell rc file,
#      because the consumer is PowerShell rather than bash.

if [[ "${EUID}" -eq 0 ]]; then
  echo "Run this as your normal user, not root."
  exit 1
fi

# --- platform ---
case "$(uname -s)" in
  Darwin)               PLATFORM=macos ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
  *)                    PLATFORM=linux ;;
esac

if ! command -v jq &>/dev/null; then
  case "${PLATFORM}" in
    macos)   echo "ERROR: jq is required. Install with: brew install jq" ;;
    windows) echo "ERROR: jq is required. Install with: winget install jqlang.jq" ;;
    *)       echo "ERROR: jq is required. Install with: sudo apt install jq" ;;
  esac
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COPILOT_DIR="${COPILOT_HOME:-${HOME}/.copilot}"

# --- link strategy and the bash binary ---
#
# LINK_MODE is symlink everywhere except a Windows machine that refuses to
# create them. winpath translates a POSIX path for consumers that are
# native Windows programs (the CLI reading the hook JSON, cmd.exe reading a
# shim); on the Unix platforms it is the identity.
LINK_MODE=symlink
BASH_EXE_WIN=""

winpath() {
  if [[ "${PLATFORM}" == "windows" ]]; then
    cygpath -m "$1"
  else
    printf '%s' "$1"
  fi
}

if [[ "${PLATFORM}" == "windows" ]]; then
  export MSYS=winsymlinks:nativestrict

  PROBE_DIR="$(mktemp -d)"
  : > "${PROBE_DIR}/probe-target"
  if ln -s "${PROBE_DIR}/probe-target" "${PROBE_DIR}/probe-link" 2>/dev/null \
     && [[ -L "${PROBE_DIR}/probe-link" ]]; then
    LINK_MODE=symlink
  else
    LINK_MODE=copy
  fi
  rm -rf "${PROBE_DIR}"

  BASH_EXE_WIN="$(winpath "$(command -v bash)")"
  [[ "${BASH_EXE_WIN}" == *.exe ]] || BASH_EXE_WIN="${BASH_EXE_WIN}.exe"
fi

echo "==> zatpilot.env-install: wiring repo config into the live system"
echo "    Repo:     ${REPO_DIR}"
echo "    Target:   ${COPILOT_DIR}"
echo "    Platform: ${PLATFORM}"

if [[ "${PLATFORM}" == "windows" ]]; then
  echo "    Links:    ${LINK_MODE}"
  if [[ "${LINK_MODE}" == "copy" ]]; then
    echo
    echo "    WARNING: this account cannot create symbolic links, so skills,"
    echo "    agents, and instructions are installed as directory junctions"
    echo "    and file COPIES. Copies go stale: re-run this installer after"
    echo "    every pull. For live links, turn on Developer Mode"
    echo "    (Settings > System > For developers) and re-run."
    echo
  fi
fi

# --- link helpers ---
#
# link_dir and link_file are the only places that know how a link is made.
# In symlink mode both are `ln -s`. In copy mode a directory becomes a
# junction (allowed without any privilege, and traversed by native programs
# like a real directory) and a file becomes a copy.
link_dir() {
  local src="$1" dest="$2"
  if [[ "${LINK_MODE}" == "symlink" ]]; then
    ln -s "${src}" "${dest}"
  else
    powershell.exe -NoProfile -Command \
      "New-Item -ItemType Junction -Path '$(winpath "${dest}")' -Target '$(winpath "${src}")' -Force | Out-Null" \
      >/dev/null
  fi
}

link_file() {
  local src="$1" dest="$2"
  if [[ "${LINK_MODE}" == "symlink" ]]; then
    ln -s "${src}" "${dest}"
  else
    cp -f "${src}" "${dest}"
  fi
}

# is_installed_link <path>: true when the path is something this installer
# put there (a symlink in symlink mode, a junction or an identical copy in
# copy mode) rather than user content that must be preserved.
is_installed_link() {
  local p="$1" src="${2:-}"
  [[ -L "${p}" ]] && return 0
  [[ "${LINK_MODE}" == "symlink" ]] && return 1
  if [[ -d "${p}" ]]; then
    # A junction reports as a reparse point to Windows but as a plain
    # directory to MSYS; ask Windows.
    local kind
    kind=$(powershell.exe -NoProfile -Command \
      "(Get-Item -LiteralPath '$(winpath "${p}")' -Force).LinkType" 2>/dev/null | tr -d '\r')
    [[ "${kind}" == "Junction" || "${kind}" == "SymbolicLink" ]] && return 0
    return 1
  fi
  [[ -n "${src}" ]] && cmp -s "${p}" "${src}" && return 0
  return 1
}

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

# Git records a path in the form it is handed. On Windows, MSYS rewrites a
# POSIX-looking argument into drive-letter form on the way into a native
# program, so what git stores is not the string this script passed. Convert
# up front and compare the same form below: without this the include guard
# never recognizes its own earlier write, and every re-run appends another
# include.path.
EXCLUDES_FILE="$(winpath "${REPO_DIR}/gitconfig/ignore-global")"
ALIASES_INCLUDE="$(winpath "${REPO_DIR}/gitconfig/aliases.gitconfig")"
git config --global core.excludesfile "${EXCLUDES_FILE}"

# include.path supports multiple values; only add if not already present
if ! git config --global --get-all include.path 2>/dev/null | grep -qF "${ALIASES_INCLUDE}"; then
  git config --global --add include.path "${ALIASES_INCLUDE}"
fi

# --- global instructions ---
INSTRUCTIONS_TARGET="${COPILOT_DIR}/copilot-instructions.md"
INSTRUCTIONS_SOURCE="${REPO_DIR}/copilot/global-copilot-instructions.md"
echo "==> Linking ${INSTRUCTIONS_TARGET} -> ${INSTRUCTIONS_SOURCE}"
mkdir -p "${COPILOT_DIR}"
if is_installed_link "${INSTRUCTIONS_TARGET}" "${INSTRUCTIONS_SOURCE}"; then
  rm -f "${INSTRUCTIONS_TARGET}"
elif [[ -e "${INSTRUCTIONS_TARGET}" ]]; then
  echo "    WARNING: ${INSTRUCTIONS_TARGET} exists and is not a symlink; moving to copilot-instructions.md.bak"
  mv "${INSTRUCTIONS_TARGET}" "${INSTRUCTIONS_TARGET}.bak"
fi
link_file "${INSTRUCTIONS_SOURCE}" "${INSTRUCTIONS_TARGET}"

# --- skills ---
echo "==> Linking skills into ${COPILOT_DIR}/skills/"
mkdir -p "${COPILOT_DIR}/skills"

for skill_dir in "${REPO_DIR}/copilot/skills"/*/; do
  skill_name="$(basename "${skill_dir}")"
  target="${COPILOT_DIR}/skills/${skill_name}"

  if is_installed_link "${target}"; then
    rm -rf "${target}"
  elif [[ -d "${target}" ]]; then
    echo "    WARNING: ${target} exists and is not a symlink; skipping ${skill_name}"
    continue
  fi

  link_dir "${skill_dir%/}" "${target}"
  echo "    ${skill_name} -> ${skill_dir}"
done

# --- agents ---
echo "==> Linking agents into ${COPILOT_DIR}/agents/"
mkdir -p "${COPILOT_DIR}/agents"

for agent_file in "${REPO_DIR}/copilot/agents"/*.agent.md; do
  agent_name="$(basename "${agent_file}")"
  target="${COPILOT_DIR}/agents/${agent_name}"

  if is_installed_link "${target}" "${agent_file}"; then
    rm -f "${target}"
  elif [[ -e "${target}" ]]; then
    echo "    WARNING: ${target} exists and is not a symlink; skipping ${agent_name}"
    continue
  fi

  link_file "${agent_file}" "${target}"
  echo "    ${agent_name} -> ${agent_file}"
done

# --- helper scripts ---
echo "==> Linking helper scripts into ${COPILOT_DIR}/bin/"
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

  link_file "${script}" "${target}"
  echo "    ${script_name} -> ${script}"

  # Windows: PowerShell is the CLI's shell and cannot run an extensionless
  # bash script, so each helper also gets a generated .cmd shim that
  # re-enters bash. The shim names the repo script directly, the same
  # convention the hook registration uses. Owned by the installer and
  # regenerated on every run. CRLF is deliberate: .cmd is a cmd.exe file.
  if [[ "${PLATFORM}" == "windows" ]]; then
    printf '@echo off\r\n"%s" "%s" %%*\r\n' \
      "${BASH_EXE_WIN}" "$(winpath "${script}")" > "${BIN_DIR}/${script_name}.cmd"
    echo "    ${script_name}.cmd -> bash ${script_name}"
  fi
done

# --- PATH entry ---
# The skills and agents invoke codereview-marker, codereview-skip, and
# spec-backlog-apply by bare name, and the user types codereview-skip
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

# Git Bash starts as a LOGIN shell, which reads ~/.bash_profile, ~/.bash_login,
# or ~/.profile and never ~/.bashrc on its own. Git for Windows warns about
# exactly this situation on every start. Create the one-line bridge so the
# PATH entry above actually applies, and so the warning stops.
if [[ "${PLATFORM}" == "windows" ]]; then
  if [[ ! -f "${HOME}/.bash_profile" && ! -f "${HOME}/.bash_login" && ! -f "${HOME}/.profile" ]]; then
    printf '%s\n' '# Created by zatpilot.env-install.sh: login shells read this, not .bashrc.' \
                  '[ -f ~/.bashrc ] && . ~/.bashrc' > "${HOME}/.bash_profile"
    echo "==> Created ${HOME}/.bash_profile so login shells source .bashrc"
  fi
fi
# Windows: the rc file only serves Git Bash. The CLI runs PowerShell, so the
# shim directory and bash itself have to be on the Windows user PATH too.
# Only the Git bin directory is added, never Git's usr/bin, which shadows
# Windows commands such as find and sort.
if [[ "${PLATFORM}" == "windows" && -z "${ZATPILOT_SKIP_WINDOWS_PATH:-}" ]]; then
  add_windows_path_entry() {
    local entry="$1" result
    result=$(powershell.exe -NoProfile -Command "
      \$entry = '${entry}'
      \$current = [Environment]::GetEnvironmentVariable('Path','User')
      if (\$null -eq \$current) { \$current = '' }
      if ((\$current -split ';') -contains \$entry) { 'present' }
      else {
        \$updated = if (\$current.Trim() -eq '') { \$entry } else { \$current.TrimEnd(';') + ';' + \$entry }
        [Environment]::SetEnvironmentVariable('Path', \$updated, 'User')
        'added'
      }" 2>/dev/null | tr -d '\r')
    echo "    ${result:-failed}: ${entry}"
  }

  echo "==> Windows user PATH"
  add_windows_path_entry "$(cygpath -w "${BIN_DIR}")"
  # The entry to add is Git's own bin directory (bash.exe, sh.exe, git.exe),
  # derived from the MSYS root. Never Git's usr/bin: that one holds the whole
  # GNU userland and would shadow Windows commands such as find and sort for
  # every process this user starts. `command -v bash` resolves to /usr/bin
  # inside MSYS, so deriving the entry from it would add exactly the wrong
  # directory.
  GIT_ROOT_MIXED="$(cygpath -m /)"
  GIT_ROOT_MIXED="${GIT_ROOT_MIXED%/}"
  if [[ -x "${GIT_ROOT_MIXED}/bin/bash.exe" ]]; then
    add_windows_path_entry "$(cygpath -w "${GIT_ROOT_MIXED}/bin")"
  else
    echo "    WARNING: no bash.exe under ${GIT_ROOT_MIXED}/bin; leaving bash off the"
    echo "    Windows PATH. PowerShell will not be able to run POSIX snippets."
  fi
  echo "    (open a new terminal to pick these up)"
elif [[ "${PLATFORM}" == "windows" ]]; then
  # ZATPILOT_SKIP_WINDOWS_PATH is set by tests/test-install.sh so a run
  # against a sandboxed HOME cannot write a temporary directory into the
  # real user PATH.
  echo "==> Windows user PATH: skipped (ZATPILOT_SKIP_WINDOWS_PATH is set)"
fi

# --- marker cache directory ---
# codereview-marker creates this on demand at mode 0700. On Windows the
# POSIX mode bits are advisory, so the real access control is an ACL: drop
# inheritance and grant the current user alone. Doing it here keeps the
# marker script a hot path with no per-call ACL work.
CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/copilot-codereview"
mkdir -p "${CACHE_DIR}"
chmod 700 "${CACHE_DIR}" 2>/dev/null || true
if [[ "${PLATFORM}" == "windows" ]]; then
  echo "==> Restricting ${CACHE_DIR} to the current user"
  icacls "$(cygpath -w "${CACHE_DIR}")" /inheritance:r /grant:r "$(whoami):(OI)(CI)F" >/dev/null 2>&1 \
    || echo "    WARNING: could not tighten the ACL; the marker directory keeps inherited permissions"
fi

# --- pre-push gate hook registration ---
# Written (not symlinked) so the JSON can carry the absolute repo path.
# Regenerated on every run; this file is owned by the installer.
#
# Copilot CLI selects the hook command by platform: a `bash` entry runs on
# macOS and Linux, a `powershell` entry runs on Windows, and neither falls
# back to the other. A Windows registration therefore carries both, with the
# powershell form re-entering bash to run the same script. Getting this
# wrong does not fail loudly; the gate simply never fires.
HOOKS_DIR="${COPILOT_DIR}/hooks"
HOOKS_JSON="${HOOKS_DIR}/zatpilot-env.json"
echo "==> Writing ${HOOKS_JSON}"
mkdir -p "${HOOKS_DIR}"
HOOK_SCRIPT="${REPO_DIR}/hooks/pre-push-codereview.sh"

if [[ "${PLATFORM}" == "windows" ]]; then
  jq -n \
    --arg cmd "$(winpath "${HOOK_SCRIPT}")" \
    --arg pscmd "& '${BASH_EXE_WIN}' '$(winpath "${HOOK_SCRIPT}")'" '{
    version: 1,
    hooks: {
      preToolUse: [
        {
          type: "command",
          bash: $cmd,
          powershell: $pscmd,
          timeoutSec: 30
        }
      ]
    }
  }' > "${HOOKS_JSON}"
else
  jq -n --arg cmd "$(winpath "${HOOK_SCRIPT}")" '{
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
fi

echo "==> Done"
echo
echo "Verify:"
echo "  git st                                           # alias from gitconfig"
echo "  ls -la ${INSTRUCTIONS_TARGET}                    # link into the repo"
echo "  ls -la ${COPILOT_DIR}/skills/                    # six skill links"
echo "  ls -la ${COPILOT_DIR}/agents/                    # five agent links"
echo "  ls -la ${BIN_DIR}/                               # three helper links"
echo "  jq . ${HOOKS_JSON}                               # gate hook registration"
echo "  bash ${REPO_DIR}/tests/run-all.sh                # full test suite"
echo
echo "In the CLI: /skills list should show the six skills, and /agent should"
echo "list the five agents. First run on a new machine, walk the validation"
if [[ "${PLATFORM}" == "windows" ]]; then
  echo "checklist in docs/windows-validation.md."
else
  echo "checklist in docs/mac-validation.md."
fi
