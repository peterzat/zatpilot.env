#!/usr/bin/env bash
set -uo pipefail

# Structural lint for the prompt/infrastructure contracts in this repo.
#
# This is a grep-based drift guard, not a behavior test. Skills, agents,
# hooks, and scripts promise each other exact strings (marker subcommands,
# META field names, mode names, gate wording). When prose is reworded or
# logic moves, these checks catch the half of a contract that did not move
# with it. Every check names the contract it pins; when a check fails,
# either restore the string or update BOTH sides and this lint together.
#
# Grows with the repo: sections are added in the same increment as the
# files they pin.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_DIR}" || exit 1

FAILS=0
TOTAL=0
pass() { TOTAL=$((TOTAL + 1)); printf '  ok   %s\n' "$1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '  FAIL %s\n' "$1"; }

# has <file> <extended-regex> <label>: file must exist and match.
has() {
  if [[ ! -f "$1" ]]; then fail "$3 [FILE MISSING: $1]"; return; fi
  if grep -qE -- "$2" "$1"; then pass "$3"; else fail "$3"; fi
}

# hasnt <file> <extended-regex> <label>: file must exist and NOT match.
hasnt() {
  if [[ ! -f "$1" ]]; then fail "$3 [FILE MISSING: $1]"; return; fi
  if grep -qE -- "$2" "$1"; then fail "$3"; else pass "$3"; fi
}

# line_of <file> <regex>: line number of first match, empty if none.
line_of() {
  grep -nE -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1
}

AGENTS_DIR="copilot/agents"
CR_AGENT="${AGENTS_DIR}/codereview.agent.md"
CF_AGENT="${AGENTS_DIR}/codefix.agent.md"
SEC_AGENT="${AGENTS_DIR}/security.agent.md"
HOOK="hooks/pre-push-codereview.sh"
SKIP="bin/codereview-skip"

# Forbidden strings are assembled by concatenation so this lint file never
# matches its own patterns.
P_ARGS='\$ARG''UMENTS'
P_CLAUDE_DIR='\~/\.''cla''ude'
P_CLAUDE_CODE='Cla''ude Code'
P_ZATENV='zat\.''env'
P_CTX_FORK='context:'' fork'
P_DMI='disable-model-''invocation'
P_ARGHINT='argument-''hint'
P_SKILLCALL='Skill\('
P_GREPOP='grep -o''P'
P_MD5='md5''sum'
P_STATC='stat -''c'
P_TIMEOUT='(^|[^a-z-])time''out '
EMDASH=$(printf '\xe2\x80\x94')

# ============================================================
echo "==> 1. Agent frontmatter"
# ============================================================

for f in "${AGENTS_DIR}"/*.agent.md; do
  name=$(basename "${f}" .agent.md)
  has "${f}" '^description:' "agent ${name}: has description"
  has "${f}" '^tools:' "agent ${name}: has tools restriction"
done

# ============================================================
echo ""
echo "==> 2. Builder/verifier boundary"
# ============================================================
#
# The reviewer must not carry edit/write tools; the fixer carries edit but
# not write. The separation is the point: an agent that fixes its own
# findings is biased toward confirming the fix worked.

cr_tools=$(grep -E '^tools:' "${CR_AGENT}" 2>/dev/null || true)
if [[ -n "${cr_tools}" && "${cr_tools}" != *edit* && "${cr_tools}" != *write* ]]; then
  pass "codereview agent: tools exclude edit and write"
else
  fail "codereview agent: tools must exclude edit and write (got: ${cr_tools})"
fi

cf_tools=$(grep -E '^tools:' "${CF_AGENT}" 2>/dev/null || true)
if [[ "${cf_tools}" == *edit* && "${cf_tools}" != *write* ]]; then
  pass "codefix agent: tools include edit, exclude write"
else
  fail "codefix agent: tools must include edit and exclude write (got: ${cf_tools})"
fi

sec_tools=$(grep -E '^tools:' "${SEC_AGENT}" 2>/dev/null || true)
if [[ "${sec_tools}" == *write* ]]; then
  pass "security agent: tools include write (owns SECURITY.md)"
else
  fail "security agent: tools must include write (got: ${sec_tools})"
fi

# The never-fix rule must appear before the first step so it frames the
# whole review, not as an afterthought.
NEVER_FIX_LINE=$(line_of "${CR_AGENT}" "Never fix code yourself")
FIRST_STEP_LINE=$(line_of "${CR_AGENT}" "^## Step 1")
if [[ -n "${NEVER_FIX_LINE}" && -n "${FIRST_STEP_LINE}" && "${NEVER_FIX_LINE}" -lt "${FIRST_STEP_LINE}" ]]; then
  pass "codereview agent: never-fix rule precedes Step 1"
else
  fail "codereview agent: never-fix rule must precede Step 1 (rule@${NEVER_FIX_LINE:-none} step@${FIRST_STEP_LINE:-none})"
fi
has "${CR_AGENT}" "biased toward confirming the fix worked" "codereview agent: states the builder/verifier rationale"

has "${CF_AGENT}" "No self-evaluation" "codefix agent: no-self-evaluation principle"
has "${CF_AGENT}" "Do not update CODEREVIEW.md" "codefix agent: forbidden from updating the review file"
has "${CF_AGENT}" "Modify CODEREVIEW.md, SECURITY.md, TESTING.md, or SPEC.md" "codefix agent: do-not list names all four artifacts"
has "${CF_AGENT}" 'Read `CODEREVIEW.md` and `SECURITY.md`' "codefix agent: reads findings from both files"
has "${CF_AGENT}" "more than 20 lines" "codefix agent: 20-line skip rule"
has "${CF_AGENT}" "revert the fix" "codefix agent: syntax-check-and-revert rule"
has "${CF_AGENT}" "Delete or weaken existing tests" "codefix agent: test-weakening ban"

# ============================================================
echo ""
echo "==> 3. Dispatch-mode and marker-authority contracts"
# ============================================================
#
# The codereview agent has two dispatch modes; only verify mode may write
# the marker, and only after the security scan is confirmed fresh. This is
# what prevents a clean code review from vouching for a diff security has
# not seen.

has "${CR_AGENT}" '^## Dispatch Modes' "codereview agent: dispatch modes section"
has "${CR_AGENT}" '\*\*initial\*\*' "codereview agent: initial mode defined"
has "${CR_AGENT}" '\*\*verify\*\*' "codereview agent: verify mode defined"
has "${CR_AGENT}" "Never write the push marker in initial mode" "codereview agent: initial mode never writes marker"
has "${CR_AGENT}" "the only mode that may run" "codereview agent: verify holds sole marker authority"

MARKER_WRITE_LINE=$(line_of "${CR_AGENT}" '^codereview-marker write$')
VERIFY_LINE=$(line_of "${CR_AGENT}" '^## Verify Mode')
if [[ -n "${MARKER_WRITE_LINE}" && -n "${VERIFY_LINE}" && "${MARKER_WRITE_LINE}" -gt "${VERIFY_LINE}" ]]; then
  pass "codereview agent: marker-write invocation lives inside verify mode"
else
  fail "codereview agent: marker-write must appear only inside verify mode (write@${MARKER_WRITE_LINE:-none} verify@${VERIFY_LINE:-none})"
fi

has "${CR_AGENT}" "security scan is stale or missing" "codereview agent: verify gates on security freshness"
has "${CR_AGENT}" "Security scope needed: fresh" "codereview agent: scope report contract (fresh)"
has "${CR_AGENT}" "Security scope needed: full" "codereview agent: scope report contract (full)"
has "${CR_AGENT}" "You never dispatch other agents" "codereview agent: orchestration stays with the skill"
has "${CR_AGENT}" "empty-tree case, NOT \"nothing to review" "codereview agent: first-push semantics"
has "${CR_AGENT}" "Do not improvise a narrower review" "codereview agent: anti-shortcut guard"
has "${CR_AGENT}" "re-report at original severity" "codereview agent: severity carry-forward"
has "${CR_AGENT}" "downgrade to NOTE" "codereview agent: accepted-risk downgrade is human-gated"
has "${CR_AGENT}" "Pressure Test" "codereview agent: pressure-test step present"
has "${SEC_AGENT}" "Pressure Test" "security agent: pressure-test step present"
has "${SEC_AGENT}" "never reproduce the" "security agent: secret redaction rule"
has "${SEC_AGENT}" "Do not re-flag accepted risks" "security agent: accepted-risk suppression"

# ============================================================
echo ""
echo "==> 4. META field contracts"
# ============================================================
#
# Field names inside the HTML-comment footers are a hard interface: the
# codereview agent's refresh detection, verify mode, the pr merge gate,
# and the /codereview skill's loop decisions all grep for them.

has "${CR_AGENT}" '"reviewed_up_to"' "codereview agent: REVIEW_META reviewed_up_to"
has "${CR_AGENT}" '"diff_hash"' "codereview agent: REVIEW_META diff_hash (verify short-circuit key)"
has "${CR_AGENT}" '"tests_pass"' "codereview agent: REVIEW_META tests_pass baseline"
has "${CR_AGENT}" '"tier"' "codereview agent: REVIEW_META tier"
has "${SEC_AGENT}" 'SECURITY_META' "security agent: writes SECURITY_META"
has "${SEC_AGENT}" '"scanned_files"' "security agent: path-scoped runs record scanned_files"
has "${CR_AGENT}" 'scanned_files' "codereview agent: freshness check reads scanned_files"

# ============================================================
echo ""
echo "==> 5. Gate alignment (hook, marker, agents)"
# ============================================================
#
# The gate is BLOCK-only: WARN and NOTE never block a push. Hook wording,
# agent wording, and (later) README must agree.

has "${HOOK}" "all BLOCK items resolved" "hook: deny reason states BLOCK-only gate"
hasnt "${HOOK}" "BLOCK and WARN" "hook: deny reason does not claim WARN gates"
has "${HOOK}" "Run /codereview now" "hook: deny reason drives the review immediately"
has "${HOOK}" "Do not offer to skip" "hook: deny reason forbids offering the bypass"
has "${HOOK}" "two separate commands" "hook: bypass documented as two separate commands"
has "${SKIP}" "separate command" "codereview-skip: documents the two-command form"
has "${HOOK}" 'permissionDecision' "hook: emits Copilot decision JSON"
has "${HOOK}" 'fromjson' "hook: double-parses toolArgs"
has "${CR_AGENT}" "tests did" "codereview agent: marker requires stable tests"
has "${CR_AGENT}" 'do not prefix with `bin/`' "codereview agent: marker script called bare"
hasnt "${CR_AGENT}" 'bin/codereview-marker' "codereview agent: no path-prefixed marker calls"

# ============================================================
echo ""
echo "==> 6. Forbidden strings (source-harness residue)"
# ============================================================
#
# The fork must stand alone: no source-repo paths, no source-harness
# mechanics in runtime surfaces. Lineage mentions are allowed only in
# README.md and NOTICE.

LINEAGE_SCOPE=()
while IFS= read -r f; do LINEAGE_SCOPE+=("$f"); done < <(find copilot bin hooks -type f 2>/dev/null | sort)

for f in "${LINEAGE_SCOPE[@]}"; do
  base=$(basename "$f")
  hasnt "$f" "${P_ARGS}" "${base}: no argument-macro residue"
  hasnt "$f" "${P_CLAUDE_DIR}" "${base}: no source-harness config paths"
  hasnt "$f" "${P_CLAUDE_CODE}" "${base}: no source-harness product names"
  hasnt "$f" "${P_ZATENV}" "${base}: no source-repo references"
  hasnt "$f" "${P_CTX_FORK}" "${base}: no fork-context frontmatter"
  hasnt "$f" "${P_DMI}" "${base}: no model-invocation frontmatter"
  hasnt "$f" "${P_ARGHINT}" "${base}: no argument-hint frontmatter"
  hasnt "$f" "${P_SKILLCALL}" "${base}: no skill-tool call syntax"
done

# ============================================================
echo ""
echo "==> 7. Portability (macOS/BSD userland)"
# ============================================================
#
# Scripts must run on stock macOS: no GNU-only flags, no md5 or bare
# sha256 hashing tools outside the detection wrapper, no GNU-only stat
# flags outside a BSD-fallback pair, no coreutils timeout.

PORT_SCOPE=()
while IFS= read -r f; do PORT_SCOPE+=("$f"); done < <(find bin hooks tests -type f \( -name '*.sh' -o -path 'bin/*' \) 2>/dev/null | sort)

for f in "${PORT_SCOPE[@]}"; do
  base=$(basename "$f")
  hasnt "$f" "${P_GREPOP}" "${base}: no PCRE grep"
  hasnt "$f" "${P_MD5}" "${base}: no md5 hashing"
  hasnt "$f" "${P_TIMEOUT}" "${base}: no coreutils timeout"
  # sha256sum may appear only alongside the shasum fallback (the wrapper).
  if grep -q 'sha256''sum' "$f" 2>/dev/null; then
    if grep -q 'shasum -a 256' "$f" 2>/dev/null; then
      pass "${base}: sha256sum only inside the portable wrapper"
    else
      fail "${base}: sha256sum without shasum fallback"
    fi
  else
    pass "${base}: sha256sum only inside the portable wrapper"
  fi
  # GNU stat flags may appear only alongside the BSD stat fallback.
  if grep -qE -- "${P_STATC}" "$f" 2>/dev/null; then
    if grep -q 'stat -f' "$f" 2>/dev/null; then
      pass "${base}: GNU stat only inside a BSD-fallback pair"
    else
      fail "${base}: GNU stat flag without BSD fallback"
    fi
  else
    pass "${base}: GNU stat only inside a BSD-fallback pair"
  fi
done

# Prompt files execute shell too; they must be equally portable.
for f in "${LINEAGE_SCOPE[@]}"; do
  base=$(basename "$f")
  hasnt "$f" "${P_GREPOP}" "${base}: prompt shell snippets avoid PCRE grep"
done

# ============================================================
echo ""
echo "==> 8. Writing style (no decorative glyphs)"
# ============================================================
#
# No em-dashes, no emoji, no checkmark glyphs in authored files. LICENSE
# is third-party text and exempt; SPEC.md checkboxes are the one allowed
# checkbox use (checked when a criterion is verified).

STYLE_SCOPE=()
while IFS= read -r f; do STYLE_SCOPE+=("$f"); done < <(find . -maxdepth 2 -type f \( -name '*.md' -o -name '*.sh' -o -path './bin/*' \) -not -path './.git/*' -not -name 'LICENSE' 2>/dev/null | sort)

for f in "${STYLE_SCOPE[@]}"; do
  base=$(basename "$f")
  hasnt "$f" "${EMDASH}" "${base}: no em-dashes"
done

# ============================================================
echo ""
echo "==> 9. shellcheck (when available)"
# ============================================================

if command -v shellcheck >/dev/null 2>&1; then
  SC_FILES=()
  while IFS= read -r f; do SC_FILES+=("$f"); done < <(find bin hooks tests -type f \( -name '*.sh' -o -path 'bin/*' \) 2>/dev/null | sort)
  if shellcheck -S warning "${SC_FILES[@]}" >/dev/null 2>&1; then
    pass "shellcheck -S warning clean (${#SC_FILES[@]} files)"
  else
    fail "shellcheck -S warning found issues (run: shellcheck -S warning ${SC_FILES[*]})"
  fi
else
  pass "shellcheck not installed; skipped"
fi

# ============================================================
echo ""
if [[ "${FAILS}" -eq 0 ]]; then
  echo "All ${TOTAL} checks passed."
else
  echo "${FAILS} of ${TOTAL} checks failed."
  exit 1
fi
