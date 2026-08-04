#!/usr/bin/env bash
set -uo pipefail

# Tests for bin/codereview-marker.
#
# Covers the three upstream-resolution cases (the script's behavioral
# contract), the empty-diff exit-2 path, hash stability, write-mode
# marker file behavior, and parity with a reference computation that
# derives the base, excludes, and truncation independently (proves the
# script implements the documented contract, not an accident of its
# own internals).

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_DIR}/bin/codereview-marker"

FAILS=0
TOTAL=0
pass() { TOTAL=$((TOTAL + 1)); printf '  ok   %s\n' "$1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '  FAIL %s\n' "$1"; }

WORK_DIR=$(mktemp -d)
cleanup() { cd /tmp || true; rm -rf "${WORK_DIR}"; }
trap cleanup EXIT

START_DIR="${PWD}"

# Portable SHA-256 of stdin, hash only. Mirrors the helper in the
# script under test; sha256sum on Linux, shasum -a 256 on macOS.
_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# Portable file mode in octal. GNU stat uses -c, BSD stat uses -f.
_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

# Initialize a git repo at $1 with one committed file. Quiet.
init_repo() {
  local dir="$1"
  mkdir -p "${dir}"
  git -C "${dir}" init -q -b main
  git -C "${dir}" config user.email "test@example"
  git -C "${dir}" config user.name "Test"
  echo "initial" > "${dir}/a.txt"
  git -C "${dir}" add a.txt
  git -C "${dir}" commit -q -m "init"
}

# Set up a bare remote at $2 and push the local repo at $1 to it.
push_to_remote() {
  local local_dir="$1" remote_dir="$2"
  git init -q --bare "${remote_dir}"
  git -C "${local_dir}" remote add origin "${remote_dir}"
  git -C "${local_dir}" push -q -u origin main
}

# Reference computation of the marker hash from the current working
# directory, written independently of the script's internals: derive
# the base (upstream, then origin/<branch>, then empty tree), diff with
# the four review files excluded, hash and truncate to 16 chars.
# Returns 2 if no reviewable changes (matching script behavior).
inline_hash() {
  local upstream base
  upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null) \
    || upstream="origin/$(git rev-parse --abbrev-ref HEAD)"
  if git rev-parse "${upstream}" >/dev/null 2>&1; then
    base="${upstream}"
  else
    base=$(git hash-object -t tree /dev/null)
  fi
  if git diff --quiet "${base}" \
    -- ':!CODEREVIEW.md' ':!SECURITY.md' ':!TESTING.md' ':!SPEC.md' 2>/dev/null; then
    return 2
  fi
  git diff "${base}" \
    -- ':!CODEREVIEW.md' ':!SECURITY.md' ':!TESTING.md' ':!SPEC.md' 2>/dev/null \
    | _sha256 | cut -c1-16
}

# --- Usage / not-in-git-repo cases ---

echo ""
echo "==> codereview-marker rejects bad invocation"
cd "${WORK_DIR}" || exit 1
err=$("${SCRIPT}" 2>&1 >/dev/null) ; ec=$?
if [[ "${ec}" -eq 1 ]]; then pass "no subcommand: exit 1"; else fail "no subcommand: expected exit 1 got ${ec}"; fi
if printf '%s' "${err}" | grep -q "Usage"; then pass "no subcommand: usage on stderr"; else fail "no subcommand: usage missing"; fi

err=$("${SCRIPT}" frobnicate 2>&1 >/dev/null) ; ec=$?
if [[ "${ec}" -eq 1 ]]; then pass "unknown subcommand: exit 1"; else fail "unknown subcommand: expected exit 1 got ${ec}"; fi

echo ""
echo "==> codereview-marker rejects non-git-repo"
NOGIT="${WORK_DIR}/nogit"
mkdir -p "${NOGIT}"
cd "${NOGIT}" || exit 1
err=$("${SCRIPT}" hash 2>&1 >/dev/null) ; ec=$?
if [[ "${ec}" -eq 1 ]]; then pass "hash outside git: exit 1"; else fail "hash outside git: expected exit 1 got ${ec}"; fi
if printf '%s' "${err}" | grep -q "not in a git repository"; then pass "hash outside git: stderr names cause"; else fail "hash outside git: stderr missing"; fi

err=$("${SCRIPT}" base 2>&1 >/dev/null) ; ec=$?
if [[ "${ec}" -eq 1 ]]; then pass "base outside git: exit 1"; else fail "base outside git: expected exit 1 got ${ec}"; fi

# --- Case (a): @{upstream} resolves ---

echo ""
echo "==> Case (a): @{upstream} resolves -> hash against that ref"
A_LOCAL="${WORK_DIR}/case_a_local"
A_REMOTE="${WORK_DIR}/case_a_remote.git"
init_repo "${A_LOCAL}"
push_to_remote "${A_LOCAL}" "${A_REMOTE}"
cd "${A_LOCAL}" || exit 1
echo "modified" > b.txt
git add b.txt
git commit -q -m "add b.txt"
if git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
  pass "case a: @{upstream} resolves (precondition)"
else
  fail "case a: @{upstream} should resolve here"
fi

hash=$("${SCRIPT}" hash) ; ec=$?
if [[ "${ec}" -eq 0 ]]; then pass "case a: hash exit 0"; else fail "case a: hash expected exit 0 got ${ec}"; fi
if [[ "${hash}" =~ ^[0-9a-f]{16}$ ]]; then pass "case a: hash is 16 hex chars"; else fail "case a: hash bad format '${hash}'"; fi

inline=$(inline_hash) ; iec=$?
if [[ "${ec}" -eq "${iec}" ]]; then pass "case a: script and inline exit codes match"; else fail "case a: exit codes diverge (script ${ec} inline ${iec})"; fi
if [[ "${hash}" == "${inline}" ]]; then pass "case a: script hash == inline hash"; else fail "case a: hash divergence (script ${hash} inline ${inline})"; fi

# `base` subcommand exposes resolve_base for the codereview agent's scope
# derivation, so the review scope matches the gate's diff base in every
# resolution case.
base=$("${SCRIPT}" base) ; bec=$?
if [[ "${bec}" -eq 0 ]]; then pass "case a: base exit 0"; else fail "case a: base expected exit 0 got ${bec}"; fi
if [[ "${base}" == "origin/main" ]]; then pass "case a: base resolves to upstream ref (origin/main)"; else fail "case a: base expected origin/main got '${base}'"; fi

# --- Case (b): @{upstream} absent but origin/<branch> resolves ---

echo ""
echo "==> Case (b): no @{upstream} but origin/<branch> exists (lost-upstream case)"
B_LOCAL="${WORK_DIR}/case_b_local"
B_REMOTE="${WORK_DIR}/case_b_remote.git"
init_repo "${B_LOCAL}"
push_to_remote "${B_LOCAL}" "${B_REMOTE}"
cd "${B_LOCAL}" || exit 1
echo "modified" > b.txt
git add b.txt
git commit -q -m "add b.txt"
git branch --unset-upstream main
if git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
  fail "case b: @{upstream} should NOT resolve after unset (precondition)"
else
  pass "case b: @{upstream} unresolved (precondition)"
fi
if git rev-parse origin/main >/dev/null 2>&1; then
  pass "case b: origin/main still resolves (precondition)"
else
  fail "case b: origin/main should still exist"
fi

hash=$("${SCRIPT}" hash) ; ec=$?
if [[ "${ec}" -eq 0 ]]; then pass "case b: hash exit 0"; else fail "case b: hash expected exit 0 got ${ec}"; fi
if [[ "${hash}" =~ ^[0-9a-f]{16}$ ]]; then pass "case b: hash is 16 hex chars"; else fail "case b: hash bad format '${hash}'"; fi

inline=$(inline_hash) ; iec=$?
if [[ "${ec}" -eq "${iec}" ]]; then pass "case b: script and inline exit codes match"; else fail "case b: exit codes diverge (script ${ec} inline ${iec})"; fi
if [[ "${hash}" == "${inline}" ]]; then pass "case b: script hash == inline hash"; else fail "case b: hash divergence (script ${hash} inline ${inline})"; fi

base=$("${SCRIPT}" base)
if [[ "${base}" == "origin/main" ]]; then pass "case b: base falls back to origin/main (no upstream)"; else fail "case b: base expected origin/main got '${base}'"; fi

# The hash MUST NOT be the empty-tree hash. This is the lost-upstream
# regression: when the base variable was lost between separate shell
# invocations, the diff silently fell through to the empty tree. The
# script must compute against origin/main.
empty_tree=$(git hash-object -t tree /dev/null)
empty_hash=$(git diff "${empty_tree}" \
  -- ':!CODEREVIEW.md' ':!SECURITY.md' ':!TESTING.md' ':!SPEC.md' 2>/dev/null \
  | _sha256 | cut -c1-16)
if [[ "${hash}" == "${empty_hash}" ]]; then
  fail "case b: hash collapsed to empty-tree fallback (lost-upstream regression)"
else
  pass "case b: hash did NOT fall through to empty-tree (lost-upstream regression guard)"
fi

# --- Case (c): no upstream, no origin -> empty-tree fallback ---

echo ""
echo "==> Case (c): neither @{upstream} nor origin/<branch> exists -> empty-tree"
C_LOCAL="${WORK_DIR}/case_c_local"
init_repo "${C_LOCAL}"
cd "${C_LOCAL}" || exit 1
echo "modified" > b.txt
git add b.txt
git commit -q -m "add b.txt"
if git rev-parse origin/main >/dev/null 2>&1; then
  fail "case c: origin/main should NOT exist (precondition)"
else
  pass "case c: origin/main absent (precondition)"
fi

hash=$("${SCRIPT}" hash) ; ec=$?
if [[ "${ec}" -eq 0 ]]; then pass "case c: hash exit 0"; else fail "case c: hash expected exit 0 got ${ec}"; fi
if [[ "${hash}" =~ ^[0-9a-f]{16}$ ]]; then pass "case c: hash is 16 hex chars"; else fail "case c: hash bad format '${hash}'"; fi

inline=$(inline_hash) ; iec=$?
if [[ "${ec}" -eq "${iec}" ]]; then pass "case c: script and inline exit codes match"; else fail "case c: exit codes diverge"; fi
if [[ "${hash}" == "${inline}" ]]; then pass "case c: script hash == inline hash"; else fail "case c: hash divergence"; fi

empty_tree=$(git hash-object -t tree /dev/null)
expected=$(git diff "${empty_tree}" \
  -- ':!CODEREVIEW.md' ':!SECURITY.md' ':!TESTING.md' ':!SPEC.md' 2>/dev/null \
  | _sha256 | cut -c1-16)
if [[ "${hash}" == "${expected}" ]]; then pass "case c: hash IS the empty-tree fallback (legitimately)"; else fail "case c: hash did not match empty-tree expected"; fi

base=$("${SCRIPT}" base)
if [[ "${base}" == "${empty_tree}" ]]; then pass "case c: base IS the empty-tree hash (first-push whole-tree scope)"; else fail "case c: base expected empty-tree ${empty_tree} got '${base}'"; fi

# --- Empty diff: only excluded files differ -> exit 2 ---

echo ""
echo "==> Empty diff: only excluded files differ -> exit 2"
D_LOCAL="${WORK_DIR}/case_d_local"
D_REMOTE="${WORK_DIR}/case_d_remote.git"
init_repo "${D_LOCAL}"
push_to_remote "${D_LOCAL}" "${D_REMOTE}"
cd "${D_LOCAL}" || exit 1
echo "review notes" > CODEREVIEW.md
echo "security notes" > SECURITY.md
git add CODEREVIEW.md SECURITY.md
git commit -q -m "review files only"

err=$("${SCRIPT}" hash 2>&1 >/dev/null) ; ec=$?
if [[ "${ec}" -eq 2 ]]; then pass "empty diff: exit 2"; else fail "empty diff: expected exit 2 got ${ec}"; fi
if printf '%s' "${err}" | grep -q "no reviewable changes"; then pass "empty diff: stderr names cause"; else fail "empty diff: stderr missing 'no reviewable changes'"; fi

# --- Empty diff: no changes at all -> exit 2 ---

echo ""
echo "==> Empty diff: no changes at all -> exit 2"
E_LOCAL="${WORK_DIR}/case_e_local"
E_REMOTE="${WORK_DIR}/case_e_remote.git"
init_repo "${E_LOCAL}"
push_to_remote "${E_LOCAL}" "${E_REMOTE}"
cd "${E_LOCAL}" || exit 1
err=$("${SCRIPT}" hash 2>&1 >/dev/null) ; ec=$?
if [[ "${ec}" -eq 2 ]]; then pass "no changes: exit 2"; else fail "no changes: expected exit 2 got ${ec}"; fi

# --- Hash stability across invocations ---

echo ""
echo "==> Hash is stable across consecutive invocations"
S_LOCAL="${WORK_DIR}/case_s_local"
S_REMOTE="${WORK_DIR}/case_s_remote.git"
init_repo "${S_LOCAL}"
push_to_remote "${S_LOCAL}" "${S_REMOTE}"
cd "${S_LOCAL}" || exit 1
echo "stable" > b.txt
git add b.txt
git commit -q -m "stable"
h1=$("${SCRIPT}" hash)
h2=$("${SCRIPT}" hash)
if [[ "${h1}" == "${h2}" ]]; then pass "stability: two hashes equal"; else fail "stability: hashes differ"; fi

# --- write subcommand ---

echo ""
echo "==> write subcommand writes marker file"
W_LOCAL="${WORK_DIR}/case_w_local"
W_REMOTE="${WORK_DIR}/case_w_remote.git"
init_repo "${W_LOCAL}"
push_to_remote "${W_LOCAL}" "${W_REMOTE}"
cd "${W_LOCAL}" || exit 1
echo "writeme" > b.txt
git add b.txt
git commit -q -m "writeme"

marker_path=$("${SCRIPT}" path)
rm -f "${marker_path}"

"${SCRIPT}" write ; ec=$?
if [[ "${ec}" -eq 0 ]]; then pass "write: exit 0"; else fail "write: expected exit 0 got ${ec}"; fi
if [[ -f "${marker_path}" ]]; then pass "write: marker file created"; else fail "write: marker file missing"; fi

hash_via_hash=$("${SCRIPT}" hash)
marker_content=$(cat "${marker_path}")
if [[ "${marker_content}" == "${hash_via_hash}" ]]; then pass "write: marker content matches hash subcommand"; else fail "write: marker content differs"; fi

rm -f "${marker_path}"

echo ""
echo "==> write subcommand: exit 2 + no marker when nothing to review"
WN_LOCAL="${WORK_DIR}/case_wn_local"
WN_REMOTE="${WORK_DIR}/case_wn_remote.git"
init_repo "${WN_LOCAL}"
push_to_remote "${WN_LOCAL}" "${WN_REMOTE}"
cd "${WN_LOCAL}" || exit 1
marker_path=$("${SCRIPT}" path)
rm -f "${marker_path}"

"${SCRIPT}" write 2>/dev/null ; ec=$?
if [[ "${ec}" -eq 2 ]]; then pass "write nothing: exit 2"; else fail "write nothing: expected exit 2 got ${ec}"; fi
if [[ ! -f "${marker_path}" ]]; then pass "write nothing: marker file NOT created"; else fail "write nothing: marker file should not exist"; fi

# --- path subcommand ---

echo ""
echo "==> path subcommand"
P_LOCAL="${WORK_DIR}/case_p_local"
init_repo "${P_LOCAL}"
cd "${P_LOCAL}" || exit 1

EXPECTED_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/copilot-codereview"

p=$("${SCRIPT}" path)
if [[ "${p}" =~ ^${EXPECTED_DIR}/marker-[0-9a-f]{8}$ ]]; then
  pass "path: matches ${EXPECTED_DIR}/marker-<8hex>"
else
  fail "path: bad format '${p}' (expected match against ${EXPECTED_DIR}/marker-<8hex>)"
fi

# path must create the marker directory at mode 0700 (per-user).
if [[ -d "${EXPECTED_DIR}" ]]; then
  pass "path: marker directory exists"
else
  fail "path: marker directory missing"
fi
mode=$(_mode "${EXPECTED_DIR}")
if [[ "${mode}" == "700" ]]; then
  pass "path: marker directory mode 0700"
else
  fail "path: marker directory mode ${mode:-?} (expected 700)"
fi

# --- skip-path subcommand ---

echo ""
echo "==> skip-path subcommand"
sp=$("${SCRIPT}" skip-path)
if [[ "${sp}" =~ ^${EXPECTED_DIR}/skip-[0-9a-f]{8}$ ]]; then
  pass "skip-path: matches ${EXPECTED_DIR}/skip-<8hex>"
else
  fail "skip-path: bad format '${sp}'"
fi

# skip-path and path must share the same project hash (same dir, same suffix).
p_hash=$(echo "${p}" | sed -E 's,^.*/marker-,,')
sp_hash=$(echo "${sp}" | sed -E 's,^.*/skip-,,')
if [[ "${p_hash}" == "${sp_hash}" ]] && [[ -n "${p_hash}" ]]; then
  pass "skip-path: shares project hash with path (${p_hash})"
else
  fail "skip-path: project-hash mismatch (path=${p_hash}, skip=${sp_hash})"
fi

# Restore original cwd before exit so trap cleanup of WORK_DIR is safe.
cd "${START_DIR}" || exit 1

# --- Summary ---

echo ""
if [[ "${FAILS}" -eq 0 ]]; then
  echo "All ${TOTAL} checks passed."
else
  echo "${FAILS} of ${TOTAL} checks failed."
  exit 1
fi
