---
name: security
description: >-
  Security review, vulnerability check, or secret scan from a Principal
  Security Engineer perspective. Scope from the invocation text: nothing for
  a full repository audit, changes-only for the working tree, or file paths.
  Dispatches the security agent; never audits in the calling context.
---

# Security Review Dispatch

Dispatch the security agent with the scope taken from the text after the
skill name in the user's message: "Use the security agent: scope
<full | changes-only | file list>." No text means a full repository audit.

**Never audit in this context.** The auditor runs as an isolated agent so its
judgment is grounded in the files, not in this conversation's assumptions.
The agent writes SECURITY.md and returns its findings; the dispatch returns
that report when it finishes (never poll for it). Relay the report verbatim,
including the severity table and the accepted-risks handling.

If naming the agent does not spawn it, tell the user to invoke it directly
with /agent or `copilot --agent security -p "full audit"`. Never audit
inline instead.
