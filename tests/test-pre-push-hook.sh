#!/usr/bin/env bash
set -uo pipefail

# Tests for hooks/pre-push-codereview.sh.
#
# Covers:
#   - is_git_push detection across many command forms (the bug that motivated
#     this suite: `git -C <dir> push` and other prefix variants silently
#     bypassed the gate)
#   - is_tag_only_push detection, scoped to each push's own refspecs
#   - The Copilot hook decision contract: deny/allow JSON on stdout, silent
#     abstain for non-push commands, exit 2 only for infrastructure failure
#   - Wire-format handling: toolName filter, toolArgs as JSON string or
#     object, malformed toolArgs fail closed
#   - Marker file hash match / mismatch, skip marker consumption
#   - PATH-independent marker-script resolution via the sibling bin/

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${REPO_DIR}/hooks/pre-push-codereview.sh"

# The repo's bin/ is prepended so the test is self-contained on a fresh
# checkout where the installer has not run yet. PATH-independence of the
# hook itself is tested separately with a sanitized PATH.
export PATH="${REPO_DIR}/bin:${PATH}"

FAILS=0
TOTAL=0
pass() { TOTAL=$((TOTAL + 1)); printf '  ok   %s\n' "$1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '  FAIL %s\n' "$1"; }

# Build the Copilot-shaped payload for a shell command. toolArgs is a
# JSON-encoded STRING per the documented wire format.
#
# The command goes in over stdin rather than through --arg. On Windows,
# MSYS rewrites any argv value that looks like a POSIX path before a native
# program sees it, so `--arg c '/usr/bin/bash -lc "git push"'` reaches jq as
# 'C:/Program Files/Git/usr/bin/bash ...' and the suite would quietly test a
# different command than the one it names. Stdin is never rewritten.
payload_for() {
  printf '%s' "$1" | jq -Rs '{toolName: "bash", toolArgs: ({command: .} | tostring)}'
}

# Run the hook in a directory with a given payload. Sets HOOK_EC, HOOK_OUT
# (stdout), HOOK_ERR (stderr).
run_hook_raw() {
  local dir="$1" payload="$2"
  local outf errf
  outf=$(mktemp); errf=$(mktemp)
  HOOK_EC=0
  (cd "${dir}" && printf '%s' "${payload}" | bash "${HOOK}" >"${outf}" 2>"${errf}") || HOOK_EC=$?
  HOOK_OUT=$(cat "${outf}")
  HOOK_ERR=$(cat "${errf}")
  rm -f "${outf}" "${errf}"
}

# Classify the last run: deny | allow | abstain (empty stdout).
decision_of() {
  if [[ -z "${HOOK_OUT}" ]]; then printf 'abstain'; return; fi
  printf '%s' "${HOOK_OUT}" | jq -r '.permissionDecision // "abstain"' 2>/dev/null || printf 'abstain'
}

reason_of() {
  printf '%s' "${HOOK_OUT}" | jq -r '.permissionDecisionReason // ""' 2>/dev/null || printf ''
}

# expect <dir> <cmd> <expected-decision> <expected-ec> <label>
expect() {
  local dir="$1" cmd="$2" want_dec="$3" want_ec="$4" label="$5"
  run_hook_raw "${dir}" "$(payload_for "${cmd}")"
  local dec
  dec=$(decision_of)
  if [[ "${HOOK_EC}" -eq "${want_ec}" && "${dec}" == "${want_dec}" ]]; then
    pass "${label}"
  else
    fail "${label} (expected ${want_dec}/exit ${want_ec}, got ${dec}/exit ${HOOK_EC})"
  fi
}

# Set up a throwaway git repo with one committed file, so we have a
# meaningful diff to test against and a well-defined upstream.
setup_test_repo() {
  TEST_REPO=$(mktemp -d)
  git -C "${TEST_REPO}" init -q -b main
  git -C "${TEST_REPO}" config user.email test@test.invalid
  git -C "${TEST_REPO}" config user.name "test"
  # Windows: a global core.autocrlf would rewrite the fixtures on checkout,
  # perturbing the diff the marker hashes and adding a warning to every
  # git call. Pin the fixture repos to LF.
  git -C "${TEST_REPO}" config core.autocrlf false
  echo "first" > "${TEST_REPO}/file.txt"
  git -C "${TEST_REPO}" add file.txt
  git -C "${TEST_REPO}" commit -q -m "initial"
  # Fake an upstream by creating refs/remotes/origin/main pointing at HEAD.
  git -C "${TEST_REPO}" update-ref refs/remotes/origin/main HEAD
  # Resolve marker paths via the same script the hook uses, so the test is
  # invariant to the path scheme.
  TEST_MARKER=$(cd "${TEST_REPO}" && codereview-marker path)
  TEST_SKIP_MARKER=$(cd "${TEST_REPO}" && codereview-marker skip-path)
  rm -f "${TEST_MARKER}" "${TEST_SKIP_MARKER}"
}

teardown_test_repo() {
  rm -rf "${TEST_REPO}"
  rm -f "${TEST_MARKER}" "${TEST_SKIP_MARKER}"
}

# ----------------------------------------------------------------------
# Setup
# ----------------------------------------------------------------------

# A scratch directory that is NOT a git repo, used for detection-only tests.
SCRATCH_NOGIT=$(mktemp -d)
trap 'rm -rf "${SCRATCH_NOGIT}"; rm -rf "${TEST_REPO:-}"; rm -f "${TEST_MARKER:-}" "${TEST_SKIP_MARKER:-}"' EXIT

# A sanitized PATH that keeps git and jq but drops the repo bin/. Used to
# prove the hook's marker-script resolution does not depend on PATH.
JQ_BIN_DIR="$(dirname "$(command -v jq)")"
GIT_BIN_DIR="$(dirname "$(command -v git)")"
PATH_SANITIZED="${JQ_BIN_DIR}:${GIT_BIN_DIR}:/usr/bin:/bin"

# ============================================================
echo "==> Detection: positive cases (push detected, non-repo dir, abstain)"
# ============================================================
#
# In a non-git directory, the hook abstains for a detected push via the
# "not in a git repo" branch, and also abstains for non-push commands via
# the early exit. Both yield abstain/exit 0 here; the dispatch blocks below
# exercise the same commands in a real repo where the outcomes diverge.

for cmd in \
  "git push" \
  "git push origin main" \
  "git -C /tmp push" \
  "git -c user.name=foo push" \
  "git -c user.name=foo -c user.email=bar push" \
  "git --git-dir=/tmp/x push" \
  "git --work-tree=/tmp/x push" \
  "git --namespace=foo push" \
  "git --exec-path=/usr/lib/git-core push" \
  "git --super-prefix=sub push" \
  "git -C /home/peter/src push" \
  "git add . && git push" \
  "git commit -m done && git push" \
  "( cd /tmp && git push )" \
  "git push --force-with-lease"; do
  expect "${SCRATCH_NOGIT}" "${cmd}" abstain 0 "detects as push (no-git-repo abstain): ${cmd}"
done

# ============================================================
echo ""
echo "==> Detection: negative cases (should NOT be classified as git push)"
# ============================================================

for cmd in \
  "git status" \
  "git diff" \
  "git log --oneline" \
  "git commit -m push" \
  "git commit -m \"fix push bug\"" \
  "git branch --list" \
  "echo git push" \
  "echo 'git push is a command'" \
  "cat /tmp/notes-about-git-push.txt" \
  "grep -r 'git push' docs/" \
  "ls -la" \
  ""; do
  expect "${SCRATCH_NOGIT}" "${cmd}" abstain 0 "passes through: ${cmd}"
done

# ============================================================
echo ""
echo "==> Dispatch: real repo, no diff -> empty-diff abstain path"
# ============================================================

setup_test_repo
# Working tree matches upstream; the non-excluded diff is empty.
run_hook_raw "${TEST_REPO}" "$(payload_for "git push")"
if [[ "${HOOK_EC}" -eq 0 && "$(decision_of)" == "abstain" ]]; then
  pass "no-diff: abstain, exit 0"
else
  fail "no-diff: expected abstain/exit 0, got $(decision_of)/exit ${HOOK_EC}"
fi
if [[ "${HOOK_ERR}" == *"nothing to review"* ]]; then
  pass "no-diff: stderr explains why gate passed"
else
  fail "no-diff: expected 'nothing to review' on stderr, got: ${HOOK_ERR}"
fi
teardown_test_repo

# ============================================================
echo ""
echo "==> Dispatch: real repo, diff exists, no marker -> deny JSON"
# ============================================================

setup_test_repo
echo "modified" > "${TEST_REPO}/file.txt"
run_hook_raw "${TEST_REPO}" "$(payload_for "git push")"
if [[ "${HOOK_EC}" -eq 0 && "$(decision_of)" == "deny" ]]; then
  pass "diff-no-marker: deny JSON, exit 0"
else
  fail "diff-no-marker: expected deny/exit 0, got $(decision_of)/exit ${HOOK_EC}"
fi
reason=$(reason_of)
if [[ "${reason}" == *"Run /codereview now"* ]]; then
  pass "diff-no-marker: reason carries the coaching text"
else
  fail "diff-no-marker: reason missing 'Run /codereview now': ${reason}"
fi
if [[ "${reason}" == *"Do not offer to skip"* ]]; then
  pass "diff-no-marker: reason forbids offering the bypass"
else
  fail "diff-no-marker: reason missing 'Do not offer to skip'"
fi
if [[ "${reason}" == *"two separate commands"* ]]; then
  pass "diff-no-marker: reason states the two-command bypass form"
else
  fail "diff-no-marker: reason missing 'two separate commands'"
fi
teardown_test_repo

# ============================================================
echo ""
echo "==> Dispatch: real repo, diff exists, marker matches -> allow JSON"
# ============================================================

setup_test_repo
echo "modified" > "${TEST_REPO}/file.txt"
EXPECTED=$(cd "${TEST_REPO}" && codereview-marker hash)
echo "${EXPECTED}" > "${TEST_MARKER}"
run_hook_raw "${TEST_REPO}" "$(payload_for "git push")"
if [[ "${HOOK_EC}" -eq 0 && "$(decision_of)" == "allow" ]]; then
  pass "diff-marker-match: allow JSON, exit 0"
else
  fail "diff-marker-match: expected allow/exit 0, got $(decision_of)/exit ${HOOK_EC}"
fi
if [[ "$(reason_of)" == *"marker match"* ]]; then
  pass "diff-marker-match: reason names the marker match"
else
  fail "diff-marker-match: reason missing 'marker match'"
fi
if [[ -f "${TEST_MARKER}" ]]; then
  pass "diff-marker-match: marker preserved after allow"
else
  fail "diff-marker-match: marker was consumed (should persist)"
fi
teardown_test_repo

# ============================================================
echo ""
echo "==> Dispatch: real repo, diff exists, marker stale -> deny"
# ============================================================

setup_test_repo
echo "modified" > "${TEST_REPO}/file.txt"
echo "0000000000000000" > "${TEST_MARKER}"
expect "${TEST_REPO}" "git push" deny 0 "diff-marker-stale: deny"
teardown_test_repo

# ============================================================
echo ""
echo "==> Dispatch: skip marker present -> allow and consume"
# ============================================================

setup_test_repo
echo "modified" > "${TEST_REPO}/file.txt"
touch "${TEST_SKIP_MARKER}"
run_hook_raw "${TEST_REPO}" "$(payload_for "git push")"
if [[ "${HOOK_EC}" -eq 0 && "$(decision_of)" == "allow" ]]; then
  pass "skip-marker: allow JSON, exit 0"
else
  fail "skip-marker: expected allow/exit 0, got $(decision_of)/exit ${HOOK_EC}"
fi
if [[ ! -f "${TEST_SKIP_MARKER}" ]]; then
  pass "skip-marker: consumed on use"
else
  fail "skip-marker: should have been deleted"
fi
teardown_test_repo

# ============================================================
echo ""
echo "==> Dispatch: tag-only pushes abstain (no code content)"
# ============================================================

setup_test_repo
echo "modified" > "${TEST_REPO}/file.txt"
expect "${TEST_REPO}" "git push --tags" abstain 0 "tag-push --tags: abstain"
teardown_test_repo

setup_test_repo
echo "modified" > "${TEST_REPO}/file.txt"
expect "${TEST_REPO}" "git push origin v1.2" abstain 0 "tag-push origin v1.2: abstain"
teardown_test_repo

# ============================================================
echo ""
echo "==> Regression: the -C <dir> bug that motivated this suite"
# ============================================================

setup_test_repo
echo "modified" > "${TEST_REPO}/file.txt"
# A prefix-check hook allowed this through (bypass). It must deny.
expect "${TEST_REPO}" "git -C ${TEST_REPO} push" deny 0 "git -C <dir> push: detected and denied (was the bug)"
teardown_test_repo

# ============================================================
echo ""
echo "==> Regression: tight-packed operators and newlines must not bypass the gate"
# ============================================================
#
# Without operator normalization, a compound command whose separator is not
# surrounded by whitespace glues "git"/"push" to a neighbour, so the
# whitespace tokenizer never sees a bare token and detection returns false:
# a real code push silently bypasses the gate. This covers tight-packed
# control operators (;, &&, ||, |, &) and newline separators (common in
# multi-line agent-issued commands). Each is a genuine push and must be
# denied when a diff exists and no marker is present.
bypass_cmds=(
  'echo hi;git push'
  'true&&git push'
  'false||git push'
  'git add .;git push'
  'git push;echo done'
  'git push&'
  'cat x|git push'
  $'git add -A\ngit push'
  $'git commit -m wip\ngit push origin main'
  $'git add -A\ngit commit -m wip\ngit push'
  # Transparent prefixes (assignments and env/command/nohup/sudo wrappers)
  # must not hide the push from the back-walk detector.
  'env git push'
  'command git push'
  'GIT_TRACE=1 git push'
  'nohup git push'
  'sudo git push'
  # Arg-taking process wrappers (duration, priority, session, and buffering
  # wrappers) must not hide the push either: their numeric or option
  # arguments are transparent to the back-walk. The duration-wrapper fixture
  # is built by concatenation so this file never contains the literal the
  # portability lint forbids.
  'time''out 60 git push'
  'nice -n 10 git push'
  'ionice -c2 git push'
  'setsid git push'
  'stdbuf -o0 git push'
)
for cmd in "${bypass_cmds[@]}"; do
  setup_test_repo
  echo "modified" > "${TEST_REPO}/file.txt"
  run_hook_raw "${TEST_REPO}" "$(payload_for "${cmd}")"
  if [[ "${HOOK_EC}" -eq 0 && "$(decision_of)" == "deny" ]]; then
    pass "compound push detected+denied: $(printf '%q' "${cmd}")"
  else
    fail "compound push NOT gated (bypass): $(printf '%q' "${cmd}") (got $(decision_of)/exit ${HOOK_EC})"
  fi
  teardown_test_repo
done

# ============================================================
echo ""
echo "==> Over-detection guard: non-push compounds still pass through"
# ============================================================
#
# Operator normalization is biased toward over-detection, but it must not
# turn a command that merely contains other git subcommands (or mentions
# push) into a spurious deny. Run in a real repo with a diff so a
# false-positive detection would surface as an unexpected deny.
nonpush_cmds=(
  'git status&&git diff'
  'echo done;ls -la'
  "echo 'git push';true"
  $'git status\ngit diff'
  $'echo building\nmake all'
  # Numeric tokens are transparent in the back-walk (wrapper arguments); a
  # regular word before them must still demote the git token.
  'echo 5 git push'
)
for cmd in "${nonpush_cmds[@]}"; do
  setup_test_repo
  echo "modified" > "${TEST_REPO}/file.txt"
  expect "${TEST_REPO}" "${cmd}" abstain 0 "non-push compound passes through: $(printf '%q' "${cmd}")"
  teardown_test_repo
done

# ============================================================
echo ""
echo "==> Regression: tag-only detection is scoped to the push's own refspecs"
# ============================================================
#
# A tag-only detector that scans EVERY token in the command lets a stray
# version-like token anywhere (a commit message, an echo, an unrelated file)
# make a real code push look tag-only and SKIP the gate entirely. Each of
# these is a genuine code push and MUST be denied despite the stray token
# or the --tags flag.
tagfp_cmds=(
  'git push origin main && echo "deployed v1.0"'
  'git commit -m v2-prep && git push origin main'
  'git push origin main; cat v1.txt'
  'git push --tags origin main'
  'git push origin main v1.0'
  'git push origin v1.0 && git push origin main'
  'git push origin HEAD'
  # Version-like branch names are not tags; the anchored version pattern
  # must still gate them.
  'git push origin v2feature'
  'git push origin v1.5-hotfix'
)
for cmd in "${tagfp_cmds[@]}"; do
  setup_test_repo
  echo "modified" > "${TEST_REPO}/file.txt"
  run_hook_raw "${TEST_REPO}" "$(payload_for "${cmd}")"
  if [[ "${HOOK_EC}" -eq 0 && "$(decision_of)" == "deny" ]]; then
    pass "code push with stray tag-like token gated: $(printf '%q' "${cmd}")"
  else
    fail "code push wrongly skipped as tag-only: $(printf '%q' "${cmd}") (got $(decision_of)/exit ${HOOK_EC})"
  fi
  teardown_test_repo
done

# ============================================================
echo ""
echo "==> Genuine tag-only pushes still skip the gate (no over-gating)"
# ============================================================
#
# The conservative detector must not over-gate the common tag-push forms.
# These carry no reviewable code, so they abstain even with an uncommitted
# diff and no marker present.
tagok_cmds=(
  'git push --tags'
  'git push --tags origin'
  'git push origin v2.0.0'
  'git push origin refs/tags/v2.0.0'
  'git push origin v1.0 v2.0'
)
for cmd in "${tagok_cmds[@]}"; do
  setup_test_repo
  echo "modified" > "${TEST_REPO}/file.txt"
  expect "${TEST_REPO}" "${cmd}" abstain 0 "genuine tag-only push skips gate: $(printf '%q' "${cmd}")"
  teardown_test_repo
done

# ============================================================
echo ""
echo "==> Regression: glued subshell (git push) is detected and gated"
# ============================================================
setup_test_repo
echo "modified" > "${TEST_REPO}/file.txt"
expect "${TEST_REPO}" '(git push)' deny 0 "(git push) subshell detected and denied"
teardown_test_repo


# ============================================================
echo ""
echo "==> Regression: a push wrapped for another shell must not bypass the gate"
# ============================================================
#
# On Windows the CLI's shell tool is PowerShell, so a bash command reaches
# the hook wrapped in an interpreter call and the push tokens arrive inside
# quotes. Before quote stripping, every form below tokenized as '"git' and
# 'push"' and the walker never saw a bare git token: a silent bypass of the
# only hard gate in the system. Quotes are now stripped during
# normalization and the interpreters are transparent prefixes.

setup_test_repo
echo "modified" > "${TEST_REPO}/file.txt"

expect "${TEST_REPO}" 'bash -lc "git push"'          deny 0 "bash -lc \"git push\": detected and denied"
expect "${TEST_REPO}" "bash -c 'git push'"           deny 0 "bash -c 'git push': detected and denied"
expect "${TEST_REPO}" 'pwsh -Command "git push"'     deny 0 "pwsh -Command \"git push\": detected and denied"
expect "${TEST_REPO}" 'powershell -Command "git push"' deny 0 "powershell -Command: detected and denied"
expect "${TEST_REPO}" 'cmd /c "git push"'            deny 0 "cmd /c \"git push\": detected and denied"
expect "${TEST_REPO}" '/usr/bin/bash -lc "git push"' deny 0 "bash by absolute path: detected and denied"
expect "${TEST_REPO}" 'sh -c "cd /tmp && git push"'  deny 0 "sh -c compound: detected and denied"
expect "${TEST_REPO}" 'git push "origin" main'       deny 0 "quoted remote: detected and denied"

teardown_test_repo

# ============================================================
echo ""
echo "==> Over-detection guard: stripping quotes must not invent pushes"
# ============================================================
#
# Quote stripping widens what the tokenizer sees, so the false-positive
# guards matter more than before. A push named inside a string argument is
# still not a push in command position.

setup_test_repo
echo "modified" > "${TEST_REPO}/file.txt"

expect "${TEST_REPO}" 'echo "git push"'                       abstain 0 "echo \"git push\": still abstains"
expect "${TEST_REPO}" 'git commit -m "notes on git push"'     abstain 0 "commit message naming git push: still abstains"
expect "${TEST_REPO}" 'grep -r "git push" .'                  abstain 0 "grep for the phrase: still abstains"
expect "${TEST_REPO}" 'echo "run bash -lc \"git push\" later"' abstain 0 "echoed wrapper text: still abstains"

teardown_test_repo

# ============================================================
echo ""
echo "==> Wire format: the Windows shell tool and alternate command keys"
# ============================================================
#
# The Windows runtime tool is named powershell, which the toolName filter
# has to match, and the command may not arrive under .command. An
# unrecognized key must over-gate rather than silently abstain: abstaining
# would leave the gate blind on a payload shape the CLI is free to change.

setup_test_repo
echo "modified" > "${TEST_REPO}/file.txt"

for tool in "powershell" "PowerShell"; do
  p=$(jq -n --arg t "${tool}" '{toolName: $t, toolArgs: ({command: "git push"} | tostring)}')
  run_hook_raw "${TEST_REPO}" "${p}"
  if [[ "${HOOK_EC}" -eq 0 && "$(decision_of)" == "deny" ]]; then
    pass "toolName '${tool}': gated"
  else
    fail "toolName '${tool}': expected deny, got $(decision_of)/exit ${HOOK_EC}"
  fi
done

p=$(jq -n '{toolName: "powershell", toolArgs: {script: "git push"}}')
run_hook_raw "${TEST_REPO}" "${p}"
if [[ "${HOOK_EC}" -eq 0 && "$(decision_of)" == "deny" ]]; then
  pass "toolArgs.script instead of .command: gated"
else
  fail "toolArgs.script: expected deny, got $(decision_of)/exit ${HOOK_EC}"
fi

p=$(jq -n '{toolName: "powershell", toolArgs: {commandLine: "git push", cwd: "/tmp"}}')
run_hook_raw "${TEST_REPO}" "${p}"
if [[ "${HOOK_EC}" -eq 0 && "$(decision_of)" == "deny" ]]; then
  pass "unknown command key falls back to string scan: gated"
else
  fail "unknown command key: expected deny, got $(decision_of)/exit ${HOOK_EC}"
fi

# The fallback scan must not turn every shell call into a review demand.
p=$(jq -n '{toolName: "powershell", toolArgs: {commandLine: "git status", cwd: "/tmp"}}')
run_hook_raw "${TEST_REPO}" "${p}"
if [[ "${HOOK_EC}" -eq 0 && "$(decision_of)" == "abstain" ]]; then
  pass "unknown command key, non-push command: abstains"
else
  fail "unknown key non-push: expected abstain, got $(decision_of)/exit ${HOOK_EC}"
fi

teardown_test_repo
# ============================================================
echo ""
echo "==> Wire format: toolName filter and toolArgs variants"
# ============================================================

setup_test_repo
echo "modified" > "${TEST_REPO}/file.txt"

# A non-shell tool with push-like args is not this gate's business.
p=$(jq -n '{toolName: "write", toolArgs: ({command: "git push"} | tostring)}')
run_hook_raw "${TEST_REPO}" "${p}"
if [[ "${HOOK_EC}" -eq 0 && "$(decision_of)" == "abstain" ]]; then
  pass "non-shell toolName: abstain"
else
  fail "non-shell toolName: expected abstain/exit 0, got $(decision_of)/exit ${HOOK_EC}"
fi

# Alternate shell tool names still gate.
for tool in "shell" "Bash"; do
  p=$(jq -n --arg t "${tool}" '{toolName: $t, toolArgs: ({command: "git push"} | tostring)}')
  run_hook_raw "${TEST_REPO}" "${p}"
  if [[ "${HOOK_EC}" -eq 0 && "$(decision_of)" == "deny" ]]; then
    pass "toolName '${tool}': gated"
  else
    fail "toolName '${tool}': expected deny, got $(decision_of)/exit ${HOOK_EC}"
  fi
done

# toolArgs as a plain object (not a JSON-encoded string) is tolerated.
p=$(jq -n '{toolName: "bash", toolArgs: {command: "git push"}}')
run_hook_raw "${TEST_REPO}" "${p}"
if [[ "${HOOK_EC}" -eq 0 && "$(decision_of)" == "deny" ]]; then
  pass "toolArgs as object: gated"
else
  fail "toolArgs as object: expected deny, got $(decision_of)/exit ${HOOK_EC}"
fi

# Malformed toolArgs for a shell tool fails closed: the gate cannot see
# the command it guards.
p=$(jq -n '{toolName: "bash", toolArgs: "this is not json"}')
run_hook_raw "${TEST_REPO}" "${p}"
if [[ "${HOOK_EC}" -eq 2 ]]; then
  pass "malformed toolArgs: exit 2 (fail closed)"
else
  fail "malformed toolArgs: expected exit 2, got exit ${HOOK_EC}"
fi

# A shell payload with no command key is an empty command: abstain.
p=$(jq -n '{toolName: "bash", toolArgs: "{}"}')
run_hook_raw "${TEST_REPO}" "${p}"
if [[ "${HOOK_EC}" -eq 0 && "$(decision_of)" == "abstain" ]]; then
  pass "missing command key: abstain"
else
  fail "missing command key: expected abstain/exit 0, got $(decision_of)/exit ${HOOK_EC}"
fi

teardown_test_repo

# ============================================================
echo ""
echo "==> PATH independence: hook resolves codereview-marker via sibling bin/"
# ============================================================
#
# With the repo bin/ stripped from PATH, the hook must still work by
# resolving the marker script relative to its own location. Enforcement
# must never depend on the user's shell init.

setup_test_repo
echo "modified" > "${TEST_REPO}/file.txt"
p=$(payload_for "git push")
outf=$(mktemp); errf=$(mktemp); ec=0
(cd "${TEST_REPO}" && export PATH="${PATH_SANITIZED}" && printf '%s' "${p}" | bash "${HOOK}" >"${outf}" 2>"${errf}") || ec=$?
dec=$(jq -r '.permissionDecision // "abstain"' "${outf}" 2>/dev/null || echo abstain)
if [[ "${ec}" -eq 0 && "${dec}" == "deny" ]]; then
  pass "sanitized PATH: gate still denies via sibling bin/ resolution"
else
  fail "sanitized PATH: expected deny/exit 0, got ${dec}/exit ${ec}"
fi
rm -f "${outf}" "${errf}"
teardown_test_repo

# ============================================================
echo ""
echo "==> Fail-closed: no sibling bin/ and no PATH copy blocks the push"
# ============================================================
#
# A hook copy with no ../bin sibling and no codereview-marker on PATH must
# refuse the push (exit 2). Allowing it would silently bypass the gate
# whenever the marker tooling is missing.

HOOK_COPY_DIR="${SCRATCH_NOGIT}/hookcopy"
mkdir -p "${HOOK_COPY_DIR}"
cp "${HOOK}" "${HOOK_COPY_DIR}/pre-push-codereview.sh"
setup_test_repo
echo "modified" > "${TEST_REPO}/file.txt"
p=$(payload_for "git push")
ec=0
stderr_out=$(cd "${TEST_REPO}" && export PATH="${PATH_SANITIZED}" && printf '%s' "${p}" | bash "${HOOK_COPY_DIR}/pre-push-codereview.sh" 2>&1 >/dev/null) || ec=$?
if [[ "${ec}" -eq 2 ]] && printf '%s' "${stderr_out}" | grep -q "codereview-marker is unavailable"; then
  pass "missing codereview-marker: hook exits 2 (fail closed)"
else
  fail "missing codereview-marker: expected exit 2 with 'codereview-marker is unavailable', got ec=${ec} stderr=${stderr_out}"
fi
teardown_test_repo

# Pushes from outside any git repo still pass through (not our concern),
# even with the marker tooling unreachable.
ec=0
p=$(payload_for "git push")
(cd "${SCRATCH_NOGIT}" && export PATH="${PATH_SANITIZED}" && printf '%s' "${p}" | bash "${HOOK_COPY_DIR}/pre-push-codereview.sh" >/dev/null 2>&1) || ec=$?
if [[ "${ec}" -eq 0 ]]; then
  pass "outside any repo + missing codereview-marker: still abstains"
else
  fail "outside any repo: expected exit 0, got ${ec}"
fi

# ============================================================
echo ""
if [[ "${FAILS}" -eq 0 ]]; then
  echo "All ${TOTAL} checks passed."
else
  echo "${FAILS} of ${TOTAL} checks failed."
  exit 1
fi
