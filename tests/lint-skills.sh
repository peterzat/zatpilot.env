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
[[ -f AGENTS.md ]] && LINEAGE_SCOPE+=("AGENTS.md")
[[ -f zatpilot.env-install.sh ]] && LINEAGE_SCOPE+=("zatpilot.env-install.sh")

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
# checkbox use (checked when a criterion is verified). CODEREVIEW.md,
# SECURITY.md, and TESTING.md are generated review artifacts (rolling
# working state written by review agents, not authored sources), so they
# are out of style scope; SPEC.md and BACKLOG.md are hand-authored and
# stay in.

STYLE_SCOPE=()
while IFS= read -r f; do STYLE_SCOPE+=("$f"); done < <(find . -maxdepth 4 -type f \( -name '*.md' -o -name '*.sh' -o -path './bin/*' \) -not -path './.git/*' -not -name 'LICENSE' -not -name 'CODEREVIEW.md' -not -name 'SECURITY.md' -not -name 'TESTING.md' 2>/dev/null | sort)

for f in "${STYLE_SCOPE[@]}"; do
  base=$(basename "$f")
  hasnt "$f" "${EMDASH}" "${base}: no em-dashes"
done

# ============================================================
echo ""
echo "==> 9. Skill frontmatter and trampoline contracts"
# ============================================================
#
# Trampoline skills preserve the slash surface but must never do the
# verification work in the calling context; the whole architecture rests
# on dispatch. Names must match directory names (Copilot requirement).

SKILLS_DIR="copilot/skills"
for f in "${SKILLS_DIR}"/*/SKILL.md; do
  dir=$(basename "$(dirname "${f}")")
  has "${f}" '^name:' "skill ${dir}: has name"
  has "${f}" '^description:' "skill ${dir}: has description"
  has "${f}" "^name: ${dir}\$" "skill ${dir}: name matches directory"
done

CR_SKILL="${SKILLS_DIR}/codereview/SKILL.md"
SEC_SKILL="${SKILLS_DIR}/security/SKILL.md"

has "${CR_SKILL}" "Never review, fix, or edit files in this context" "codereview skill: dispatch-only rule"
has "${CR_SKILL}" "the codereview agent" "codereview skill: dispatches the reviewer"
has "${CR_SKILL}" "the security agent" "codereview skill: dispatches the auditor"
has "${CR_SKILL}" "the codefix agent" "codereview skill: dispatches the fixer"
has "${CR_SKILL}" "initial mode" "codereview skill: names initial mode"
has "${CR_SKILL}" "verify mode" "codereview skill: names verify mode"
has "${CR_SKILL}" "Cycle limit: 3" "codereview skill: three-cycle cap"
has "${CR_SKILL}" "never poll" "codereview skill: no-polling rule"
has "${CR_SKILL}" "codereview-marker hash" "codereview skill: deterministic pre-check"
has "${CR_SKILL}" "Security scope needed:" "codereview skill: consumes the agent scope line"
has "${CR_SKILL}" "REVIEW_META" "codereview skill: loop decisions read REVIEW_META from disk"
has "${CR_SKILL}" "SECURITY_META" "codereview skill: loop decisions read SECURITY_META from disk"
has "${CR_SKILL}" "two separate commands" "codereview skill: bypass form matches hook wording"
has "${CR_SKILL}" "Never offer the bypass" "codereview skill: bypass never offered"
has "${CR_SKILL}" "push now" "codereview skill: bypass reserved for unprompted push-now"
has "${CR_SKILL}" "verbatim" "codereview skill: relays reports verbatim"

has "${SEC_SKILL}" "the security agent" "security skill: dispatches the auditor"
has "${SEC_SKILL}" "Never audit in this context" "security skill: dispatch-only rule"
has "${SEC_SKILL}" "never poll" "security skill: no-polling rule"

# Global instructions carry the gate convention and the plan-then-spec
# convention; wording must match the hook and the spec skill.
GI="copilot/global-copilot-instructions.md"
if [[ -f "${GI}" ]]; then
  has "${GI}" "two separate commands" "global instructions: bypass form matches hook"
  has "${GI}" "never suggest it" "global instructions: bypass never suggested"
  has "${GI}" 'run `/codereview` automatically' "global instructions: blocked push runs review unprompted"
  has "${GI}" "exit plan mode and" "global instructions: plan-approval exit convention"
  has "${GI}" "the spec is the contract" "global instructions: spec-first rationale"
  has "${GI}" 'run `/spec plan`' "global instructions: plan handoff names /spec plan"
  has "${SPEC_SKILL:-copilot/skills/spec/SKILL.md}" 'exit plan mode' "spec: names the plan-approval exit convention"
fi

# ============================================================
echo ""
echo "==> 10. Spec, tester, pr contracts"
# ============================================================
#
# The spec turn cycle, the tester design flow, and the pr merge gate all
# promise exact strings to the backlog script, the artifact formats, and
# each other.

SPEC_SKILL="${SKILLS_DIR}/spec/SKILL.md"
PR_SKILL="${SKILLS_DIR}/pr/SKILL.md"
TESTER_SKILL="${SKILLS_DIR}/tester/SKILL.md"
ARCH_SKILL="${SKILLS_DIR}/architect/SKILL.md"
TESTER_AGENT="${AGENTS_DIR}/tester.agent.md"
ARCH_AGENT="${AGENTS_DIR}/architect.agent.md"
BACKLOG_SCRIPT="bin/spec-backlog-apply"

# Spec mode router and guards.
has "${SPEC_SKILL}" 'Wins over every other branch' "spec: plan keyword wins routing"
has "${SPEC_SKILL}" 'Stale proposal guard' "spec: stale-proposal guard present"
has "${SPEC_SKILL}" '5 or more' "spec: staleness threshold stated"
has "${SPEC_SKILL}" 'Under-specification escape hatch' "spec: escape hatch present"
has "${SPEC_SKILL}" 'too under-specified to produce testable acceptance criteria' "spec: escape hatch message"
has "${SPEC_SKILL}" 'Acceptance criteria are tests' "spec: criteria-are-tests principle"
has "${SPEC_SKILL}" 'Bias toward keep when unsure' "spec: sweep bias to keep"
has "${SPEC_SKILL}" 'the script owns all mutations' "spec: script-only BACKLOG mutation"
has "${SPEC_SKILL}" 'spec-backlog-apply' "spec: names the mutation script"
has "${SPEC_SKILL}" 'STOP and wait' "spec: stops after writing, no implementation"

# Plan adoption is context-first with a confirmed fallback.
has "${SPEC_SKILL}" 'approved in this session' "spec: plan adoption reads the conversation first"
has "${SPEC_SKILL}" 'session-state' "spec: session-store fallback present"
has "${SPEC_SKILL}" 'ground it before adopting' "spec: fallback plan is grounded against the repo"
has "${SPEC_SKILL}" 'Never adopt an ambiguous' "spec: ambiguous fallback plans require confirmation"
has "${SPEC_SKILL}" 'Never delete or modify a session-store plan file' "spec: plans are replay sources"
has "${SPEC_SKILL}" 'prose becomes contract' "spec: pressure test framing for plans"

# Manifest op parity between the spec skill's documentation and the script.
for op in 'delete:' 'adopt:' 'purge-origin:' 'append:' 'end-append'; do
  has "${SPEC_SKILL}" "${op}" "spec: documents manifest op ${op}"
  has "${BACKLOG_SCRIPT}" "${op}" "script: implements manifest op ${op}"
done
for tag in 'DELETED:' 'ANNOTATED:' 'PURGED:' 'APPENDED:' 'SKIPPED:' 'MISS' 'entries' ; do
  has "${BACKLOG_SCRIPT}" "${tag}" "script: emits ${tag} lines"
done

# SPEC_META field parity: writer (spec) and reader (pr body composition).
has "${SPEC_SKILL}" '"criteria_total"' "spec: SPEC_META criteria_total"
has "${SPEC_SKILL}" '"criteria_met"' "spec: SPEC_META criteria_met"
has "${PR_SKILL}" 'criteria_met/criteria_total' "pr: reads spec progress fields"

# BACKLOG four-field template appears in both producers.
for fld in 'One-line description' 'Why deferred:' 'Revisit criteria:' 'Origin:'; do
  has "${SPEC_SKILL}" "${fld}" "spec: BACKLOG template field ${fld}"
  has "${TESTER_AGENT}" "${fld}" "tester agent: BACKLOG template field ${fld}"
done
has "${SPEC_SKILL}" 'Revisit criteria are mandatory' "spec: revisit criteria mandatory rule"

# Tester design contracts.
has "${TESTER_AGENT}" '# Durable test-architecture contract' "tester agent: exact contract H1"
has "${TESTER_AGENT}" 'tester design YYYY-MM-DD' "tester agent: canonical Origin form"
has "${TESTER_AGENT}" 'purge-origin: tester design' "tester agent: revision purge op"
has "${TESTER_AGENT}" '## Pre-apply checklist' "tester agent: literal checklist heading"
has "${TESTER_AGENT}" 'Do not invoke any file-mutating tool' "tester agent: checklist precedes mutation"
has "${TESTER_AGENT}" 'Flag, never block' "tester agent: SPEC tension flags without halting"
has "${TESTER_AGENT}" 'proxy' "tester agent: proxy-over-critic philosophy"
has "${TESTER_AGENT}" 'git checkout TESTING.md' "tester agent: git is the undo mechanism"
D4_LINE=$(line_of "${TESTER_AGENT}" 'in memory')
D6_LINE=$(line_of "${TESTER_AGENT}" '^### Step D.6')
if [[ -n "${D4_LINE}" && -n "${D6_LINE}" && "${D4_LINE}" -lt "${D6_LINE}" ]]; then
  pass "tester agent: draft-in-memory precedes the write step"
else
  fail "tester agent: draft-in-memory must precede Step D.6 (draft@${D4_LINE:-none} write@${D6_LINE:-none})"
fi
has "${TESTER_AGENT}" 'TESTING_META' "tester agent: audit mode writes TESTING_META"

# pr merge gate.
has "${PR_SKILL}" 'REVIEW_BLOCKS' "pr: local gate reads block count"
has "${PR_SKILL}" 'REVIEWED_UP_TO' "pr: local gate reads reviewed_up_to"
has "${PR_SKILL}" 'merge-base --is-ancestor' "pr: ancestry check in merge gate"
has "${PR_SKILL}" 'Do not merge without a passing review' "pr: merge gated on review"
has "${PR_SKILL}" 'Never create a PR unless' "pr: PR creation is opt-in"
has "${PR_SKILL}" 'reviewDecision' "pr: remote gate reads review decision"
has "${PR_SKILL}" 'statusCheckRollup' "pr: remote gate reads CI checks"

# Trampoline dispatch for tester and architect.
has "${TESTER_SKILL}" 'the tester agent' "tester skill: dispatches the agent"
has "${TESTER_SKILL}" 'Never assess or design in this context' "tester skill: dispatch-only rule"
has "${ARCH_SKILL}" 'the architect agent' "architect skill: dispatches the agent"
has "${ARCH_SKILL}" 'Never review in this context' "architect skill: dispatch-only rule"
has "${ARCH_AGENT}" 'does not produce a persistent output file' "architect agent: terminal node"
has "${ARCH_AGENT}" 'HEALTHY' "architect agent: board verdict vocabulary"

# ============================================================
echo ""
echo "==> 11. Installer contracts"
# ============================================================

INSTALLER="zatpilot.env-install.sh"
if [[ -f "${INSTALLER}" ]]; then
  has "${INSTALLER}" 'EUID' "installer: refuses to run as root"
  has "${INSTALLER}" 'COPILOT_HOME' "installer: honors COPILOT_HOME"
  has "${INSTALLER}" 'zatpilot-env.json' "installer: writes the gate hook registration"
  has "${INSTALLER}" 'timeoutSec: 30' "installer: hook timeoutSec matches hooks/README.md"
  has "${INSTALLER}" 'include.path' "installer: aliases via guarded include.path"
  has "${INSTALLER}" 'zshrc' "installer: Darwin PATH goes to zshrc"
  has "${INSTALLER}" 'never touches' "installer: documents the no-CLI-state rule"
  has "${INSTALLER}" 'brew install jq' "installer: Darwin jq hint"
fi

# ============================================================
echo ""
echo "==> 11b. Windows port contracts"
# ============================================================
#
# Windows differs from the Unix platforms in four ways that are silent when
# they break: a bash-only hook entry never fires, PowerShell cannot run an
# extensionless script, MSYS turns ln -s into a copy, and a CRLF checkout
# makes every script unrunnable. Each of those has exactly one place in the
# repo that handles it, pinned here.

if [[ -f "${INSTALLER}" ]]; then
  has "${INSTALLER}" 'winget install jqlang.jq' "installer: Windows jq hint"
  has "${INSTALLER}" 'winsymlinks:nativestrict' "installer: asks MSYS for native symlinks"
  has "${INSTALLER}" 'LINK_MODE' "installer: probes symlink capability and reports the mode"
  has "${INSTALLER}" 'powershell: \$pscmd' "installer: Windows hook entry carries a powershell command"
  has "${INSTALLER}" '\.cmd' "installer: generates .cmd shims for PowerShell"
  has "${INSTALLER}" 'ZATPILOT_SKIP_WINDOWS_PATH' "installer: sandboxed runs can skip the user PATH write"
  has "${INSTALLER}" 'icacls' "installer: tightens the marker cache ACL on Windows"
  hasnt "${INSTALLER}" 'add_windows_path_entry .*usr/bin' "installer: never puts Git usr/bin on the Windows PATH"
fi

# The hook must recognize the Windows shell tool and survive a wrapped
# command. Both are one-line contracts with no visible failure mode.
has "${HOOK}" 'powershell' "hook: documents the Windows shell tool name"
has "${HOOK}" 'norm//\\"' "hook: strips quotes before tokenizing"
has "${HOOK}" '\.script' "hook: falls back past .command when the key differs"

# LF is not a preference here: a CR in a shebang or a heredoc delimiter
# breaks the script on every platform, and Git for Windows checks out CRLF
# by default.
if [[ -f .gitattributes ]]; then
  has .gitattributes 'eol=lf' "gitattributes: pins LF for the checkout"
  pass "gitattributes: present"
else
  fail "gitattributes: missing (Windows checkouts would be CRLF)"
fi

# A bash script committed with CRLF defeats the .gitattributes intent.
CRLF_OFFENDERS=$(git ls-files --eol 2>/dev/null | grep -c 'i/crlf' || true)
if [[ "${CRLF_OFFENDERS}" -eq 0 ]]; then
  pass "no file is stored with CRLF in the index"
else
  fail "${CRLF_OFFENDERS} files are stored with CRLF in the index"
fi

# PowerShell resolves a bare name through PATHEXT, which never covers .sh;
# a helper named foo.sh is handed to the Windows file association instead of
# being executed. Helpers stay extensionless.
for helper in bin/*; do
  case "${helper}" in
    *.sh) fail "$(basename "${helper}"): helper scripts must not end in .sh (PowerShell cannot invoke them)" ;;
    *)    pass "$(basename "${helper}"): invocable by bare name on Windows" ;;
  esac
done

if [[ -f docs/windows-validation.md ]]; then
  has docs/windows-validation.md 'powershell' "windows-validation: covers the PowerShell shell tool"
  has docs/windows-validation.md 'toolName' "windows-validation: covers hook wire format"
  has docs/windows-validation.md 'Developer Mode' "windows-validation: covers the symlink prerequisite"
  has docs/windows-validation.md '\.cmd' "windows-validation: covers the shim path"
else
  fail "docs/windows-validation.md missing"
fi

if [[ -f zatpilot.env-install.ps1 ]]; then
  has zatpilot.env-install.ps1 'zatpilot.env-install.sh' "ps1 launcher: delegates to the one installer"
  hasnt zatpilot.env-install.ps1 'New-Item -ItemType SymbolicLink' "ps1 launcher: carries no install logic"
else
  fail "zatpilot.env-install.ps1 missing"
fi

# ============================================================
echo ""
echo "==> 12. README and docs alignment"
# ============================================================
#
# README documents the enforcement model for downstream users; its claims
# must match what the hook and agents actually do.

if [[ -f README.md ]]; then
  has README.md 'bitter-lesson-of-agentic-coding' "README: links the design article"
  has README.md 'Must fix before pushing' "README: severity table matches the gate"
  has README.md 'two separate commands' "README: bypass form matches hook wording"
  has README.md 'Timeouts fail open|timeouts fail open' "README: names the fail-open residual risk"
  has README.md '## Differences from zat' "README: differences section below the fold"
  has README.md 'hard fork' "README: states the fork relationship"
  has README.md 'friction, not' "README: reviewer boundary stated honestly (validated live)"
  has "${CR_AGENT}" 'separate simple' "codereview agent: bookkeeping reads as simple commands"
  # Coding Practices mirror: first and last bullets pinned in both files.
  for phrase in 'Work in small, committable increments' 'pushing is a shared-state action'; do
    has README.md "${phrase}" "README: coding practices mirror (${phrase%% *} bullet)"
    has copilot/global-copilot-instructions.md "${phrase}" "global instructions: coding practices source (${phrase%% *} bullet)"
  done
fi
if [[ -f docs/mac-validation.md ]]; then
  has docs/mac-validation.md '/skills list' "mac-validation: covers skill discovery"
  has docs/mac-validation.md 'toolName' "mac-validation: covers hook wire format"
  has docs/mac-validation.md '/bin/bash' "mac-validation: covers bash 3.2 run"
  has docs/mac-validation.md 'session-state' "mac-validation: covers plan fallback"
fi

# ============================================================
echo ""
echo "==> 13. shellcheck (when available)"
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
