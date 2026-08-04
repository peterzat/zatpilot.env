---
name: architect
description: >-
  Strategic architecture review from a Senior Architecture Review Board
  perspective. Manual invocation only via /architect; never invoke
  automatically. Use when the user explicitly asks for an architecture
  review, design assessment, technology selection review, or strategic
  direction evaluation. Focused deep-dives: /architect deps, /architect ops,
  /architect <topic>. Dispatches the architect agent; never reviews in the
  calling context.
---

# Architecture Review Dispatch

Dispatch the architect agent with the focus taken from the text after the
skill name in the user's message: "Use the architect agent: focus
<deps | ops | topic>." No text means the full ten-dimension review.

**Never review in this context.** The board runs as an isolated agent so
its judgment comes from the repository state, not this conversation's
assumptions. The agent writes no persistent file; its assessment informs
human decisions and must not feed automated review loops. The dispatch
returns its report when it finishes (never poll for it). Relay the report
verbatim, including the per-dimension priorities and the HEALTHY / WATCH /
ACT board recommendation.

If naming the agent does not spawn it, tell the user to invoke it directly
with /agent or `copilot --agent architect -p "full review"`. Never review
inline instead.
