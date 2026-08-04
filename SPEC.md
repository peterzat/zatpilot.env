## Spec - 2026-08-04 - Copilot CLI port of the zat.env environment

**Goal:** Stand up zatpilot.env as a standalone, fully tested port of the
zat.env agentic-coding environment to GitHub Copilot CLI, ready for live
validation on a machine with the CLI installed.

### Acceptance Criteria

- [x] All seven roles exist: spec and pr as in-context skills; codereview,
  security, tester, and architect as dispatch skills; codereview, codefix,
  security, tester, and architect as isolated agents with tool restrictions.
- [x] The pre-push gate implements the Copilot hook wire format: denies
  unreviewed pushes with coaching in the decision reason, allows
  marker-matched pushes, abstains for non-push and tag-only commands, and
  fails closed on infrastructure errors (tests/test-pre-push-hook.sh).
- [x] The marker, skip, and backlog scripts are macOS-portable (no GNU-only
  tools) and bash 3.2 safe (guarded empty-array expansions), enforced by
  lint sweeps and behavior suites.
- [x] The installer wires ~/.copilot idempotently in a sandboxed double-run
  test and never touches CLI-owned state files (tests/test-install.sh).
- [x] tests/run-all.sh passes in full on Linux.
- [x] README.md stands alone, links the design article, and documents the
  differences from zat.env below the fold; NOTICE carries the source
  attribution.
- [ ] Skills and agents are discovered from symlinks by the live CLI
  (docs/mac-validation.md items 1-2).
- [ ] The gate fires end-to-end in the live CLI: deny with visible coaching,
  allow after /codereview, skip bypass consumed (items 4, 5, 17).
- [ ] The agent tools restriction is honored: the codereview agent cannot
  edit files (item 3).
- [ ] /spec plan adopts a plan from the conversation after plan-mode
  approval, and the session-store fallback asks before adopting (items 11-12).
- [ ] The full test suite passes under /bin/bash 3.2 on macOS (item 13).

### Context

Built on a Linux machine without the Copilot CLI installed; every criterion
that requires the live CLI is deferred to docs/mac-validation.md and left
unchecked until validated there. The spec skill's framework read points at
~/src/zatpilot.env/README.md by convention. Format contracts for the review
artifacts are identical to the source environment, with REVIEW_META gaining
diff_hash and tests_pass/tests_fail fields for the sibling-dispatch review
cycle.

<!-- SPEC_META: {"date":"2026-08-04","title":"Copilot CLI port of the zat.env environment","criteria_total":11,"criteria_met":6} -->
