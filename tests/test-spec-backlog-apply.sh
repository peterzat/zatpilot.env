#!/usr/bin/env bash
set -uo pipefail

# Tests for bin/spec-backlog-apply.
#
# Covers:
#   - delete: and adopt: regression (unchanged by purge-origin addition)
#   - purge-origin: match, ACTIVE preservation, zero-match success,
#     backtick and bullet-marker variations, empty-prefix safety,
#     combination with delete/adopt in one manifest
#   - missing BACKLOG.md fall-through
#
# The single-op-type sections (a manifest with only delete:, only adopt:,
# only purge-origin:, or only append:) double as the bash 3.2 regression
# surface: each leaves the other op arrays empty, which crashes under
# `set -u` on stock macOS bash unless the script guards its loops. Keep
# them single-op. Run this suite under /bin/bash on macOS to prove it.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_DIR}/bin/spec-backlog-apply"

FAILS=0
TOTAL=0
pass() { TOTAL=$((TOTAL + 1)); printf '  ok   %s\n' "$1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '  FAIL %s\n' "$1"; }

TEST_DIR=$(mktemp -d)
cleanup() { rm -rf "${TEST_DIR}"; }
trap cleanup EXIT

# Build a standard multi-entry BACKLOG.md fixture at $1.
fixture_standard() {
  cat > "$1" <<'EOF'
# Backlog

Durable register of considered proposals.

### keep-spec
- **One-line description** generic spec item.
- **Why deferred:** not now.
- **Revisit criteria:** when ready.
- **Origin:** spec 2026-04-01

### tester-one
- **One-line description** first tester rollout.
- **Why deferred:** rollout.
- **Revisit criteria:** tier lands.
- **Origin:** `tester design 2026-04-24`

### tester-active (ACTIVE in spec 2026-04-20)
- **One-line description** tester item adopted into a spec.
- **Why deferred:** originally deferred.
- **Revisit criteria:** drift probe added.
- **Origin:** `tester design 2026-04-20`

### tester-two
- **One-line description** second tester rollout.
- **Why deferred:** rollout.
- **Revisit criteria:** tier lands.
- **Origin:** tester design 2026-04-24

### star-bullet
* **One-line description** uses asterisk bullets.
* **Why deferred:** rollout.
* **Revisit criteria:** tier lands.
* **Origin:** `tester design 2026-04-24`

### tester-minus-dash
- **One-line description** false-positive canary.
- **Why deferred:** has hyphenated origin.
- **Revisit criteria:** never match.
- **Origin:** tester-design-other 2026-04-24
EOF
}

# ============================================================
echo "==> delete: regression"
# ============================================================

BACKLOG="${TEST_DIR}/BACKLOG.md"
fixture_standard "${BACKLOG}"
pushd "${TEST_DIR}" >/dev/null || exit
OUT=$(bash "${SCRIPT}" <<'MANIFEST' 2>&1
delete: keep-spec
MANIFEST
)
EC=$?
popd >/dev/null || exit
if [[ "${EC}" -eq 0 ]]; then pass "delete: exit 0"; else fail "delete: expected exit 0, got ${EC}"; fi
if echo "${OUT}" | grep -q "^DELETED: keep-spec$"; then pass "delete: DELETED line emitted"; else fail "delete: missing DELETED line"; fi
if ! grep -q "^### keep-spec$" "${BACKLOG}"; then pass "delete: entry removed from file"; else fail "delete: entry still present"; fi
if grep -q "^### tester-active (ACTIVE" "${BACKLOG}"; then pass "delete: other entries preserved"; else fail "delete: unrelated entry missing"; fi

# ============================================================
echo ""
echo "==> delete: miss emits MISS and exits non-zero"
# ============================================================

fixture_standard "${BACKLOG}"
pushd "${TEST_DIR}" >/dev/null || exit
OUT=$(bash "${SCRIPT}" <<'MANIFEST' 2>&1
delete: does-not-exist
MANIFEST
)
EC=$?
popd >/dev/null || exit
if [[ "${EC}" -ne 0 ]]; then pass "delete miss: non-zero exit"; else fail "delete miss: expected non-zero exit"; fi
if echo "${OUT}" | grep -q "^MISS: delete: does-not-exist"; then pass "delete miss: MISS line on stderr"; else fail "delete miss: missing MISS line"; fi

# ============================================================
echo ""
echo "==> adopt: regression"
# ============================================================

fixture_standard "${BACKLOG}"
pushd "${TEST_DIR}" >/dev/null || exit
OUT=$(bash "${SCRIPT}" <<'MANIFEST' 2>&1
adopt: keep-spec | 2026-04-24
MANIFEST
)
EC=$?
popd >/dev/null || exit
if [[ "${EC}" -eq 0 ]]; then pass "adopt: exit 0"; else fail "adopt: expected exit 0, got ${EC}"; fi
if echo "${OUT}" | grep -q "^ANNOTATED: keep-spec (ACTIVE in spec 2026-04-24)$"; then pass "adopt: ANNOTATED line emitted"; else fail "adopt: missing ANNOTATED line"; fi
if grep -q "^### keep-spec (ACTIVE in spec 2026-04-24)$" "${BACKLOG}"; then pass "adopt: heading annotated in file"; else fail "adopt: annotation not present"; fi

# ============================================================
echo ""
echo "==> purge-origin: basic match purges non-ACTIVE entries"
# ============================================================

fixture_standard "${BACKLOG}"
pushd "${TEST_DIR}" >/dev/null || exit
OUT=$(bash "${SCRIPT}" <<'MANIFEST' 2>&1
purge-origin: tester design
MANIFEST
)
EC=$?
popd >/dev/null || exit
if [[ "${EC}" -eq 0 ]]; then pass "purge-origin: exit 0"; else fail "purge-origin: expected exit 0, got ${EC}"; fi
if echo "${OUT}" | grep -q "^PURGED: tester-one (origin prefix: tester design)$"; then pass "purge-origin: PURGED tester-one"; else fail "purge-origin: missing PURGED tester-one"; fi
if echo "${OUT}" | grep -q "^PURGED: tester-two (origin prefix: tester design)$"; then pass "purge-origin: PURGED tester-two"; else fail "purge-origin: missing PURGED tester-two"; fi
if echo "${OUT}" | grep -q "^PURGED: star-bullet (origin prefix: tester design)$"; then pass "purge-origin: PURGED star-bullet (asterisk bullets)"; else fail "purge-origin: missing PURGED star-bullet"; fi
if ! grep -q "^### tester-one$" "${BACKLOG}"; then pass "purge-origin: tester-one removed from file"; else fail "purge-origin: tester-one still present"; fi
if ! grep -q "^### tester-two$" "${BACKLOG}"; then pass "purge-origin: tester-two removed from file"; else fail "purge-origin: tester-two still present"; fi
if ! grep -q "^### star-bullet$" "${BACKLOG}"; then pass "purge-origin: star-bullet removed from file"; else fail "purge-origin: star-bullet still present"; fi

# ============================================================
echo ""
echo "==> purge-origin: ACTIVE entries preserved even when prefix matches"
# ============================================================

if grep -q "^### tester-active (ACTIVE in spec 2026-04-20)$" "${BACKLOG}"; then pass "purge-origin: ACTIVE entry preserved"; else fail "purge-origin: ACTIVE entry incorrectly removed"; fi
if ! echo "${OUT}" | grep -q "tester-active"; then pass "purge-origin: ACTIVE entry not listed as PURGED"; else fail "purge-origin: ACTIVE entry incorrectly listed"; fi

# ============================================================
echo ""
echo "==> purge-origin: unrelated entries (non-matching prefix) preserved"
# ============================================================

if grep -q "^### keep-spec$" "${BACKLOG}"; then pass "purge-origin: spec-origin entry preserved"; else fail "purge-origin: spec-origin entry removed"; fi
if grep -q "^### tester-minus-dash$" "${BACKLOG}"; then pass "purge-origin: hyphenated-origin entry preserved (prefix boundary)"; else fail "purge-origin: hyphenated-origin incorrectly matched"; fi

# ============================================================
echo ""
echo "==> purge-origin: zero matches returns success with no PURGED lines"
# ============================================================

fixture_standard "${BACKLOG}"
pushd "${TEST_DIR}" >/dev/null || exit
OUT=$(bash "${SCRIPT}" <<'MANIFEST' 2>&1
purge-origin: nothing-matches
MANIFEST
)
EC=$?
popd >/dev/null || exit
if [[ "${EC}" -eq 0 ]]; then pass "purge-origin zero-match: exit 0"; else fail "purge-origin zero-match: expected exit 0, got ${EC}"; fi
if ! echo "${OUT}" | grep -q "^PURGED:"; then pass "purge-origin zero-match: no PURGED lines"; else fail "purge-origin zero-match: unexpected PURGED lines"; fi
if ! echo "${OUT}" | grep -q "^MISS:"; then pass "purge-origin zero-match: no MISS lines (unlike delete/adopt)"; else fail "purge-origin zero-match: unexpected MISS line"; fi

# ============================================================
echo ""
echo "==> purge-origin: empty prefix is ignored (safety)"
# ============================================================

fixture_standard "${BACKLOG}"
pushd "${TEST_DIR}" >/dev/null || exit
OUT=$(bash "${SCRIPT}" <<'MANIFEST' 2>&1
purge-origin:
MANIFEST
)
EC=$?
popd >/dev/null || exit
# Empty prefix means no ops in total, script exits 0 before touching file.
if [[ "${EC}" -eq 0 ]]; then pass "purge-origin empty: exit 0"; else fail "purge-origin empty: expected exit 0, got ${EC}"; fi
if ! echo "${OUT}" | grep -q "^PURGED:"; then pass "purge-origin empty: no PURGED lines"; else fail "purge-origin empty: unexpected PURGED line (would match everything)"; fi
# Verify no entries were purged (all still present).
if grep -q "^### tester-one$" "${BACKLOG}"; then pass "purge-origin empty: did not touch file"; else fail "purge-origin empty: file was modified"; fi

# ============================================================
echo ""
echo "==> purge-origin: combined with delete and adopt in one manifest"
# ============================================================

fixture_standard "${BACKLOG}"
pushd "${TEST_DIR}" >/dev/null || exit
OUT=$(bash "${SCRIPT}" <<'MANIFEST' 2>&1
delete: keep-spec
adopt: tester-one | 2026-04-24
purge-origin: tester design
MANIFEST
)
EC=$?
popd >/dev/null || exit
if [[ "${EC}" -eq 0 ]]; then pass "combined: exit 0"; else fail "combined: expected exit 0, got ${EC}"; fi
if echo "${OUT}" | grep -q "^DELETED: keep-spec$"; then pass "combined: delete ran"; else fail "combined: delete missing"; fi
if echo "${OUT}" | grep -q "^ANNOTATED: tester-one (ACTIVE in spec 2026-04-24)$"; then pass "combined: adopt ran"; else fail "combined: adopt missing"; fi
# tester-one was adopted (ACTIVE), so it should NOT be purged.
if grep -q "^### tester-one (ACTIVE in spec 2026-04-24)$" "${BACKLOG}"; then pass "combined: adopt protects from purge"; else fail "combined: adopted entry was purged"; fi
# tester-two has no adopt, should be purged.
if echo "${OUT}" | grep -q "^PURGED: tester-two"; then pass "combined: purge ran on non-adopted entry"; else fail "combined: purge did not run"; fi
if ! grep -q "^### tester-two$" "${BACKLOG}"; then pass "combined: tester-two removed"; else fail "combined: tester-two still present"; fi

# ============================================================
echo ""
echo "==> purge-origin: missing BACKLOG.md falls through with message"
# ============================================================

rm -f "${BACKLOG}"
pushd "${TEST_DIR}" >/dev/null || exit
OUT=$(bash "${SCRIPT}" <<'MANIFEST' 2>&1
purge-origin: tester design
MANIFEST
)
EC=$?
popd >/dev/null || exit
if [[ "${EC}" -eq 0 ]]; then pass "missing file: exit 0"; else fail "missing file: expected exit 0, got ${EC}"; fi
if echo "${OUT}" | grep -q "BACKLOG.md not found"; then pass "missing file: fall-through message"; else fail "missing file: missing fall-through message"; fi

# ============================================================
echo ""
echo "==> purge-origin: multiple prefixes in one manifest"
# ============================================================

fixture_standard "${BACKLOG}"
pushd "${TEST_DIR}" >/dev/null || exit
OUT=$(bash "${SCRIPT}" <<'MANIFEST' 2>&1
purge-origin: tester design
purge-origin: spec
MANIFEST
)
EC=$?
popd >/dev/null || exit
if [[ "${EC}" -eq 0 ]]; then pass "multi-prefix: exit 0"; else fail "multi-prefix: expected exit 0, got ${EC}"; fi
if echo "${OUT}" | grep -q "^PURGED: tester-one"; then pass "multi-prefix: purged tester-design match"; else fail "multi-prefix: missing tester purge"; fi
if echo "${OUT}" | grep -q "^PURGED: keep-spec"; then pass "multi-prefix: purged spec match"; else fail "multi-prefix: missing spec purge"; fi
if grep -q "^### tester-active (ACTIVE in spec 2026-04-20)$" "${BACKLOG}"; then pass "multi-prefix: ACTIVE entry still preserved"; else fail "multi-prefix: ACTIVE incorrectly removed"; fi

# ============================================================
echo ""
echo "==> append: basic new entry"
# ============================================================

fixture_standard "${BACKLOG}"
pushd "${TEST_DIR}" >/dev/null || exit
OUT=$(bash "${SCRIPT}" <<'MANIFEST' 2>&1
append: fresh-rollout
- **One-line description** brand new entry.
- **Why deferred:** out of scope for current contract seed.
- **Revisit criteria:** when CI lands.
- **Origin:** `tester design 2026-04-24`
end-append
MANIFEST
)
EC=$?
popd >/dev/null || exit
if [[ "${EC}" -eq 0 ]]; then pass "append: exit 0"; else fail "append: expected exit 0, got ${EC}"; fi
if echo "${OUT}" | grep -q "^APPENDED: fresh-rollout$"; then pass "append: APPENDED line emitted"; else fail "append: missing APPENDED line"; fi
if grep -q "^### fresh-rollout$" "${BACKLOG}"; then pass "append: entry heading in file"; else fail "append: heading not in file"; fi
if grep -q "brand new entry" "${BACKLOG}"; then pass "append: body in file"; else fail "append: body missing"; fi
if grep -q "^### keep-spec$" "${BACKLOG}"; then pass "append: preexisting entries untouched"; else fail "append: existing entry lost"; fi

# ============================================================
echo ""
echo "==> append: collision with non-ACTIVE heading is SKIPPED"
# ============================================================

fixture_standard "${BACKLOG}"
pushd "${TEST_DIR}" >/dev/null || exit
OUT=$(bash "${SCRIPT}" <<'MANIFEST' 2>&1
append: keep-spec
- **One-line description** duplicate heading attempt.
- **Why deferred:** should be skipped.
- **Revisit criteria:** never.
- **Origin:** `tester design 2026-04-24`
end-append
MANIFEST
)
EC=$?
popd >/dev/null || exit
if [[ "${EC}" -eq 0 ]]; then pass "append collision: exit 0"; else fail "append collision: expected exit 0, got ${EC}"; fi
if echo "${OUT}" | grep -q "^SKIPPED: keep-spec"; then pass "append collision: SKIPPED line"; else fail "append collision: missing SKIPPED line"; fi
if ! echo "${OUT}" | grep -q "^APPENDED: keep-spec"; then pass "append collision: no APPENDED line"; else fail "append collision: should not have appended"; fi
# Count occurrences of "### keep-spec" -- must stay at 1.
keep_count=$(grep -c "^### keep-spec$" "${BACKLOG}" || true)
if [[ "${keep_count}" -eq 1 ]]; then pass "append collision: no duplicate heading created"; else fail "append collision: expected 1 keep-spec heading, got ${keep_count}"; fi

# ============================================================
echo ""
echo "==> append: collision with ACTIVE-annotated heading is SKIPPED"
# ============================================================

fixture_standard "${BACKLOG}"
pushd "${TEST_DIR}" >/dev/null || exit
OUT=$(bash "${SCRIPT}" <<'MANIFEST' 2>&1
append: tester-active
- **One-line description** attempting to shadow an ACTIVE entry.
- **Why deferred:** should be skipped.
- **Revisit criteria:** never.
- **Origin:** `tester design 2026-04-24`
end-append
MANIFEST
)
EC=$?
popd >/dev/null || exit
if [[ "${EC}" -eq 0 ]]; then pass "append ACTIVE collision: exit 0"; else fail "append ACTIVE collision: expected exit 0, got ${EC}"; fi
if echo "${OUT}" | grep -q "^SKIPPED: tester-active"; then pass "append ACTIVE collision: SKIPPED line"; else fail "append ACTIVE collision: missing SKIPPED line"; fi
# Original ACTIVE heading must still be intact.
if grep -q "^### tester-active (ACTIVE in spec 2026-04-20)$" "${BACKLOG}"; then pass "append ACTIVE collision: ACTIVE heading preserved"; else fail "append ACTIVE collision: ACTIVE heading altered"; fi

# ============================================================
echo ""
echo "==> append: creates BACKLOG.md with header if file missing"
# ============================================================

rm -f "${BACKLOG}"
pushd "${TEST_DIR}" >/dev/null || exit
OUT=$(bash "${SCRIPT}" <<'MANIFEST' 2>&1
append: first-ever-entry
- **One-line description** first entry in a new file.
- **Why deferred:** bootstrap.
- **Revisit criteria:** immediately.
- **Origin:** `tester design 2026-04-24`
end-append
MANIFEST
)
EC=$?
popd >/dev/null || exit
if [[ "${EC}" -eq 0 ]]; then pass "append create: exit 0"; else fail "append create: expected exit 0, got ${EC}"; fi
if [[ -f "${BACKLOG}" ]]; then pass "append create: BACKLOG.md created"; else fail "append create: file not created"; fi
if grep -q "^# Backlog$" "${BACKLOG}"; then pass "append create: header written"; else fail "append create: missing # Backlog header"; fi
if grep -q "^### first-ever-entry$" "${BACKLOG}"; then pass "append create: entry written"; else fail "append create: entry missing"; fi
if echo "${OUT}" | grep -q "^APPENDED: first-ever-entry$"; then pass "append create: APPENDED line"; else fail "append create: missing APPENDED line"; fi

# ============================================================
echo ""
echo "==> append: unterminated block errors out"
# ============================================================

fixture_standard "${BACKLOG}"
pushd "${TEST_DIR}" >/dev/null || exit
OUT=$(bash "${SCRIPT}" <<'MANIFEST' 2>&1
append: dangling
- **One-line description** no end-append follows.
- **Why deferred:** forgot delimiter.
MANIFEST
)
EC=$?
popd >/dev/null || exit
if [[ "${EC}" -ne 0 ]]; then pass "append unterminated: non-zero exit"; else fail "append unterminated: expected non-zero exit"; fi
if echo "${OUT}" | grep -q "missing end-append"; then pass "append unterminated: error message"; else fail "append unterminated: missing error message"; fi
# File must not have a partial write.
if ! grep -q "^### dangling$" "${BACKLOG}"; then pass "append unterminated: no partial write"; else fail "append unterminated: partial entry written"; fi

# ============================================================
echo ""
echo "==> append: combined purge+append round-trips as expected"
# ============================================================

fixture_standard "${BACKLOG}"
pushd "${TEST_DIR}" >/dev/null || exit
OUT=$(bash "${SCRIPT}" <<'MANIFEST' 2>&1
purge-origin: tester design
append: tester-one
- **One-line description** revised rollout entry.
- **Why deferred:** replaced older version.
- **Revisit criteria:** next turn.
- **Origin:** `tester design 2026-04-24`
end-append
append: tester-active
- **One-line description** duplicate of ACTIVE entry.
- **Why deferred:** should be skipped.
- **Revisit criteria:** never.
- **Origin:** `tester design 2026-04-24`
end-append
MANIFEST
)
EC=$?
popd >/dev/null || exit
if [[ "${EC}" -eq 0 ]]; then pass "combined purge+append: exit 0"; else fail "combined purge+append: expected exit 0, got ${EC}"; fi
# Old tester-one was purged (non-ACTIVE), new tester-one appended.
if echo "${OUT}" | grep -q "^PURGED: tester-one"; then pass "combined purge+append: old tester-one purged"; else fail "combined purge+append: old tester-one not purged"; fi
if echo "${OUT}" | grep -q "^APPENDED: tester-one$"; then pass "combined purge+append: new tester-one appended"; else fail "combined purge+append: new tester-one not appended"; fi
if grep -q "revised rollout entry" "${BACKLOG}"; then pass "combined purge+append: new body in file"; else fail "combined purge+append: new body missing"; fi
# ACTIVE entry preserved through purge, append skipped.
if grep -q "^### tester-active (ACTIVE in spec 2026-04-20)$" "${BACKLOG}"; then pass "combined purge+append: ACTIVE preserved"; else fail "combined purge+append: ACTIVE removed"; fi
if echo "${OUT}" | grep -q "^SKIPPED: tester-active"; then pass "combined purge+append: duplicate append SKIPPED"; else fail "combined purge+append: duplicate append not skipped"; fi

# ============================================================
echo ""
if [[ "${FAILS}" -eq 0 ]]; then
  echo "All ${TOTAL} checks passed."
else
  echo "${FAILS} of ${TOTAL} checks failed."
  exit 1
fi
