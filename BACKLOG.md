# Backlog

Durable register of considered proposals that were deferred, scoped out, or
rejected. Read before drafting a new SPEC.md; swept at turn close.

### external-reviewer-port

- **One-line description** Port the multi-provider external reviewer fan-out
  (review-external.sh and codereview's external-only mode) so reviews can get
  second opinions from other model vendors.
- **Why deferred:** Advanced feature outside the core turn loop, and the CLI
  is already multi-vendor via /model; the provider-key config and cost
  surface need a rethink before porting.
- **Revisit criteria:** A concrete need for cross-vendor second opinions on
  reviews, or span-of-release audits of already-pushed history.
- **Origin:** spec 2026-08-04

### copilot-permissions-baseline

- **One-line description** A managed allow/deny permission baseline applied
  at install time, replacing per-session interactive approvals for the
  routine command set.
- **Why deferred:** The CLI's settings.json is JSONC and CLI-owned; there is
  no documented safe path for scripted edits, and the installer's rule is to
  never touch CLI-owned state.
- **Revisit criteria:** A documented settings schema or CLI command for
  scripted permission baselines.
- **Origin:** spec 2026-08-04

### fleet-implement-mode

- **One-line description** Use /fleet parallel subagents as an implement-phase
  engine for specs whose criteria decompose into independent work items.
- **Why deferred:** Fleet subagents share one filesystem with no locking, so
  concurrent writers can silently lose work; unacceptable under a
  verification-first philosophy.
- **Revisit criteria:** The CLI ships worktree isolation or file locking for
  fleet subagents.
- **Origin:** spec 2026-08-04

### skill-preapproval-allowed-tools

- **One-line description** Add allowed-tools pre-approvals to the skill
  frontmatter (e.g. the marker script for /codereview) to cut permission
  prompts inside the review cycle.
- **Why deferred:** The value syntax for scoped pre-approvals is not
  documented well enough to risk a skill failing to load over a malformed
  field.
- **Revisit criteria:** Syntax confirmed against the live CLI during
  mac-validation, or documented in the skills reference.
- **Origin:** spec 2026-08-04
