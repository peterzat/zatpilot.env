## Review - 2026-08-04 (commit: 6d87890)

**Summary:** First-push whole-tree review of the initial zatpilot.env port (35
files) against the empty-tree base, with a chained full security audit. The
code review pass found no BLOCK or WARN issues in the port itself; the
security audit surfaced two WARN gate-bypass vectors in the push detection
heuristics, both fixed and regression-tested across two fix cycles. Test
suite improved from 650 to 657 checks, all passing; no regressions against
the baseline. Review caveat: this review ran in the session that authored the
code rather than in an isolated context; the compensations were fresh
residue/reference sweeps, a fresh suite run, the independently forked
security audit, and the per-increment lint and behavior coverage. The fork's
own isolated-agent review runs as part of live-CLI validation.

**External reviewers:**
None configured.

### Findings

[NOTE] hooks/pre-push-codereview.sh:230 -- toolName filter rests on an unverified live-CLI assumption
  Evidence: the gate applies only when toolName contains bash or shell; the
  actual tool name string the CLI sends is unconfirmed until
  docs/mac-validation.md item 4 runs on a live machine.
  Suggested fix: none now; validation item already tracks it.

[NOTE] tests/test-pre-push-hook.sh:131 -- hardcoded home path in a detection fixture
  Evidence: `git -C /home/peter/src push` as a token-parsing input; works
  everywhere but embeds a real username in a committed test string.
  Suggested fix: optional; any absolute path exercises the same tokenizer
  behavior.

### Fixes Applied

- [WARN] hooks/pre-push-codereview.sh:191 -- tag-only heuristic accepted
  version-like branch names; version pattern anchored to the whole refspec
  (^v[0-9]+(\.[0-9]+)*$). Branch names like v2feature now gate; genuine tags
  v1.2, v2.0.0, refs/tags/* still skip. (cycle 1, from the security audit)
- [WARN] hooks/pre-push-codereview.sh:102 -- command-position rule was
  defeated by transparent prefixes; replaced with a backward walk over
  assignments, prefix words (env/command/exec/nohup/time/sudo/builtin/
  xargs), and option tokens. Prefixed pushes now gate; "echo git push" still
  passes through. (cycle 1, from the security audit)
- [WARN] tests/test-pre-push-hook.sh -- added seven regression cases for the
  hardened detection: five transparent-prefix pushes and two version-like
  branch refspecs, all asserting deny. (cycle 2)
- [WARN] tests/lint-skills.sh -- glyph sweep scoped to authored sources;
  generated review artifacts (CODEREVIEW.md, SECURITY.md, TESTING.md) are
  exempt and follow their writers' house style. (cycle 2)

### Accepted Risks

None.

---
*Prior review: none; this is the first review of the repository.*

<!-- REVIEW_META: {"date":"2026-08-04","commit":"6d87890","reviewed_up_to":"6d87890a163cf99d860e639a322dc12e29b3f5e5","base":"4b825dc642cb6eb9a060e54bf8d69288fbee4904","tier":"full","block":0,"warn":0,"note":2} -->
