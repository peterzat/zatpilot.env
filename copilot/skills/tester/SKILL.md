---
name: tester
description: >-
  Test strategy review and design from a Principal SDE/T perspective.
  /tester audits the current test strategy and appends a dated finding to
  TESTING.md; /tester design writes (or revises) the durable
  test-architecture contract and seeds rollout items in BACKLOG.md. Manual
  invocation only via /tester; never invoke automatically. Dispatches the
  tester agent; never assesses in the calling context.
---

# Test Strategy Dispatch

Dispatch the tester agent with the mode taken from the text after the skill
name in the user's message: "Use the tester agent: <audit | design> mode."
No text means audit mode. Exactly `design` means design mode. Anything else:
stop with "Unknown mode for /tester: `<args>`. Use `/tester` (audit) or
`/tester design` (architecture design)." without dispatching.

**Never assess or design in this context.** The strategist runs as an
isolated agent so its judgment comes from the repository state, not this
conversation's assumptions. The agent writes TESTING.md (and BACKLOG.md
via the mutation script in design mode); the dispatch returns its report
when it finishes (never poll for it). Relay the report verbatim, including
design mode's pre-apply checklist and the revert instructions.

If naming the agent does not spawn it, tell the user to invoke it directly
with /agent or `copilot --agent tester -p "audit mode"`. Never assess
inline instead.
