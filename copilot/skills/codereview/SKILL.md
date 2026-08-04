---
name: codereview
description: >-
  Adversarial code review of the current diff against the push base, with a
  security scan and an auto-fix cycle, ending in the push marker on success.
  Use when the user asks to review code or check changes before pushing, and
  automatically whenever the pre-push gate denies a push. Exception: if the
  user has explicitly said "push now" unprompted, do not use this skill; run
  codereview-skip, then git push, as two separate commands. Orchestrates
  isolated agents; never reviews in the calling context.
---

# Code Review Orchestrator

This skill coordinates the review cycle. It does no reviewing itself.

**Never review, fix, or edit files in this context.** Your only jobs are
dispatch, bookkeeping from on-disk state, and relaying agent reports. The
reviewer and fixer run as isolated agents because clean context is the point:
a context that wrote the code reviews it badly, and an agent that fixes its
own findings is biased toward confirming the fix worked. If you catch yourself
reading the diff to form an opinion, stop and dispatch instead.

**Never offer the bypass.** The one-time bypass exists only for when the user
says "push now" unprompted: codereview-skip, then git push, as two separate
commands. Do not suggest it, and do not run this skill in that case.

Each agent dispatch returns that agent's report when it finishes; wait for it
and never poll: no sleep loops, no pgrep, no watching files for changes.

## Step 1: Pre-check

```bash
codereview-marker hash
```

Exit 2 means no reviewable changes (empty diff vs the push base, or only
review-output files differ). Report "Nothing to review." and stop.

## Step 2: Initial review

Dispatch the codereview agent: "Use the codereview agent: initial mode review
of the current diff." Relay its findings summary when it returns.

The agent writes the preliminary CODEREVIEW.md (even when clean), records the
diff hash and test baseline in REVIEW_META, and reports the security scope
needed. It never writes the push marker.

## Step 3: Security scan

Read the `Security scope needed:` line from the agent's report.

- `fresh`: skip the scan; the prior SECURITY.md still covers the surface.
- `full` or a file list: dispatch the security agent: "Use the security agent:
  scope <full | file list>." It writes SECURITY.md and returns its findings.

A light-tier review (docs only, stated in the agent's report) skips the scan.

## Step 4: Fix cycle

Loop decisions come from disk, never from conversation memory:

```bash
grep 'REVIEW_META' CODEREVIEW.md | sed -n 's/.*"block"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p'
grep 'REVIEW_META' CODEREVIEW.md | sed -n 's/.*"warn"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p'
grep 'SECURITY_META' SECURITY.md | sed -n 's/.*"block"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p'
grep 'SECURITY_META' SECURITY.md | sed -n 's/.*"warn"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p'
```

If every count is 0 (or SECURITY.md is absent because the scan was skipped as
fresh or light), go to Step 5.

Otherwise run fix-and-verify cycles:

1. Dispatch the codefix agent: "Use the codefix agent to fix the BLOCK and
   WARN findings recorded in CODEREVIEW.md and SECURITY.md."
2. Dispatch the codereview agent: "Use the codereview agent: verify mode.
   Codefix reported: <the codefix agent's report>." Verify mode re-reviews,
   re-runs tests, and either writes the marker and final entry or updates
   CODEREVIEW.md with what remains.
3. If verify reports unresolved BLOCKs, repeat from 1.

**Cycle limit: 3.** At most three codefix dispatches per run. If BLOCKs remain
after 3 cycles, or tests regressed, stop and report "requires manual
intervention." When in doubt about how many cycles have run, stop and report
rather than dispatching again.

## Step 5: Verify and close

If no fix cycle was needed, dispatch the codereview agent: "Use the codereview
agent: verify mode." It confirms security freshness, applies the short-circuit
for an unchanged clean diff, writes the push marker, and writes the final
CODEREVIEW.md entry.

## Step 6: Relay

Relay the verify report's summary table and final verdict to the user
verbatim. Do not re-summarize, soften, or second-guess agent findings; the
human reads the reviewer's words, not a paraphrase.

## If dispatch does not engage

If naming an agent does not spawn it (the CLI shows no subagent activity),
tell the user to invoke it directly with /agent (picker) or
`copilot --agent codereview -p "initial mode review"`. Never fall back to
reviewing in this context; a same-context review is worse than no review
because it records confidence the process did not earn.
