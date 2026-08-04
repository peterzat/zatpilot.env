## Review - 2026-08-04 (commit: f4c31f6)

**Summary:** Full review of the validation follow-ups (README and
mac-validation honesty rewordings, verification-based plan-adoption
fallback, agent bookkeeping guidance, lint pins), the README onboarding
restructure (quick start first, typed turn-loop walkthrough), and the
wrapper-transparency gate fix. The chained scoped security scan
(hooks/pre-push-codereview.sh, tests/test-pre-push-hook.sh,
tests/lint-skills.sh) found one WARN, fixed in one cycle with six
regression cases. Suite grew 660 to 666, all passing, no regressions.

**External reviewers:**
None configured.

### Findings

[NOTE] hooks/pre-push-codereview.sh:199 -- branch named exactly like a version tag skips the gate
  Evidence: a branch literally named v2 or v1.2 matches the anchored
  version pattern and is presumed a tag; reproduced by the security scan.
  Documented residual of the accepted anchoring fix.
  Suggested fix: none now; cheap hardening later is resolving refspecs via
  git show-ref --verify refs/tags/<r> with the repo check moved ahead of
  the tag-only check.

[NOTE] hooks/pre-push-codereview.sh:230 -- toolName filter rests on an unverified assumption on other CLI versions
  Evidence: validated on 1.0.78 (the shell tool matched); future CLI
  versions could rename the tool. mac-validation item 4 covers re-checking.
  Suggested fix: none; validation item tracks it.

[NOTE] tests/test-pre-push-hook.sh:131 -- hardcoded home path in a detection fixture
  Evidence: carried forward unresolved from the prior review at unchanged
  severity.
  Suggested fix: optional; any absolute path exercises the same tokenizer
  behavior.

### Fixes Applied

- [WARN] hooks/pre-push-codereview.sh:117 -- arg-taking process wrappers
  hid pushes from the gate; wrapper word set extended (nice, ionice,
  setsid, stdbuf, caffeinate, the coreutils duration wrapper) and pure
  numeric or duration tokens made transparent in the back-walk. Five deny
  regression cases and one pass-through negative added; verified deny for
  the wrapper forms and pass-through for "echo 5 git push". (from the
  scoped security scan)

### Accepted Risks

None.

---
*Prior review (2026-08-04): first-push whole-tree review; two WARN gate
bypasses found by the full security audit, fixed and regression-tested; 0
BLOCK remaining.*

<!-- REVIEW_META: {"date":"2026-08-04","commit":"f4c31f6","reviewed_up_to":"f4c31f62a7ba6b68ab165c2bb41a2702ad1988ab","base":"origin/main","tier":"full","block":0,"warn":0,"note":3,"diff_hash":"c56f8e1bde14bc05","tests_pass":666,"tests_fail":0} -->
