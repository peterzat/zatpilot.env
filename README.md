# zatpilot.env

A disciplined agentic-coding environment for GitHub Copilot CLI: a spec-driven
turn loop, persistent review artifacts, role-separated review agents with clean
context, and one hard gate that keeps unreviewed code off the remote.

The design philosophy behind this environment is written up in
[The Bitter Lesson of Agentic Coding](https://agent-hypervisor.ai/posts/bitter-lesson-of-agentic-coding/):
invest in verification and goal-setting, not implementation control. Everything
here follows from that argument. Read it first if you want the why; read on for
the how.

zatpilot.env is a standalone hard fork of
[zat.env](https://github.com/peterzat/zat.env), the same system built for a
different CLI harness. See [Differences from zat.env](#differences-from-zatenv)
below the fold.

## Contents

- [Quick start](#quick-start)
- [Typical workflow: the turn loop](#typical-workflow-the-turn-loop)
- [Roles: skills and agents](#roles-skills-and-agents)
- [The pre-push gate](#the-pre-push-gate)
- [Severity model](#severity-model)
- [Persistent review files](#persistent-review-files)
- [Cross-skill context graph](#cross-skill-context-graph)
- [Implement-phase autonomy](#implement-phase-autonomy)
- [Coding practices](#coding-practices)
- [Philosophy](#philosophy)
- [Anti-patterns](#anti-patterns)
- [Validating on a new machine](#validating-on-a-new-machine)
- [References](#references)
- [Differences from zat.env](#differences-from-zatenv)

## Quick start

Prerequisites: git, jq, and GitHub Copilot CLI
([install docs](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli);
`npm install -g @github/copilot` or `brew install --cask copilot-cli`).

```bash
git clone https://github.com/peterzat/zatpilot.env.git ~/src/zatpilot.env
cd ~/src/zatpilot.env
./zatpilot.env-install.sh
```

The installer is idempotent. It prompts for git identity only when unset, and:

| Target | Source |
|--------|--------|
| `~/.copilot/copilot-instructions.md` | symlink to `copilot/global-copilot-instructions.md` |
| `~/.copilot/skills/<name>` | symlinks to the six skill directories |
| `~/.copilot/agents/<name>.agent.md` | symlinks to the five agent files |
| `~/.copilot/bin/` | symlinks to the three helper scripts, added to PATH |
| `~/.copilot/hooks/zatpilot-env.json` | generated registration for the pre-push gate |
| git globals | aliases include, global ignore file, `init.defaultBranch main` |

It never modifies the CLI's own state or settings files. Open a new shell
(for PATH), start `copilot`, and check that `/skills list` shows the six
skills and `/agent` lists the five agents. On a first install, walk
[docs/mac-validation.md](docs/mac-validation.md) once to confirm the
CLI-dependent behaviors.

Then, in any project:

```
copilot          # from the project root
/model           # pick a strong reasoning model; the review loop needs one
/spec            # start the first turn
```

## Typical workflow: the turn loop

One full turn, as you actually type it:

```
/spec                    # re-orient: picks up where the project left off
Shift+Tab                # plan mode, when the next step needs exploring
  ...discuss, approve, choose "exit plan mode and I will prompt myself"
/spec plan               # the approved plan becomes SPEC.md criteria
implement the spec       # interactive, or Shift+Tab into autopilot
/spec                    # checks off met criteria; repeat until all are met
run git push             # the gate denies, /codereview runs, the push lands
```

A **turn** is one pass through that plan-spec-implement-evaluate loop.

1. **Plan.** For non-trivial work, enter plan mode (Shift+Tab, or `/plan`).
   Plan mode is the exploratory thinking space: read-only (the CLI hard-blocks
   workspace edits while planning), multi-turn, cheap to abandon. Discuss until
   the approach is right.
2. **Spec.** At plan approval, choose "exit plan mode and I will prompt
   myself", then run `/spec plan`. The spec skill converts the approved plan
   into SPEC.md: testable acceptance criteria, pressure-tested. This is the
   commit point where exploratory prose becomes a verification contract. For
   work that needs no planning conversation, `/spec <description>` writes the
   contract directly.
3. **Implement.** Work against SPEC.md, interactively or on autopilot (see
   [Implement-phase autonomy](#implement-phase-autonomy)). Intervene with
   manual direction as needed.
4. **Evolve.** `/spec` (no arguments) checks off met criteria and reports what
   is left. Repeat 3-4 until all criteria are met.
5. **Close the turn.** When the last criterion is checked, `/spec` runs a
   retrospective, sweeps the backlog, and writes a proposal for the next turn
   into SPEC.md.
6. **Push.** `git push` is gated: it requires a passing `/codereview` (which
   chains the security scan and the fix cycle) for the exact diff being pushed.
7. **Next turn.** `/spec` detects the proposal and uses it as the input brief.

**Why the spec sits between plan and implementation.** The plan approval menu
offers a shortcut that starts building immediately. This environment
deliberately does not use it: the approved plan is prose, and prose is not a
contract. `/spec plan` extracts verifiable outcomes from the plan and
pressure-tests them; those criteria are what let the implement phase run
autonomously and what the review loop verifies against. Strong success
criteria are the autonomy lever. Weak or absent criteria force constant
clarification: agents drift, optimize for making tests pass rather than
solving the problem, and "works but not good enough" stays vague indefinitely.

**Clear between turns.** Turn boundaries are a natural place to start a fresh
session (`/clear`, or quit and relaunch). The proposal and SPEC.md are on
disk, so a fresh session loses nothing and gains a clean context window.

Start every session with `/spec`. It re-orients from current state: picking up
a proposal, reporting progress, or prompting you to define what to build.

## Roles: skills and agents

Seven roles, split across two mechanisms by one rule: **roles that judge work
run as isolated agents; roles that co-author intent with you run in the
conversation.**

The split is not stylistic. The measured result behind the
[design article](https://agent-hypervisor.ai/posts/bitter-lesson-of-agentic-coding/)
is that a context reviewing code it just wrote produces far worse reviews than
a clean context reviewing the same defects, no matter how adversarial the
prompt. Copilot custom agents get their own context window; that is the
mechanism that makes "fresh eyes" real. The slash surface is preserved by thin
dispatch skills, so `/codereview` still works; it orchestrates agents rather
than reviewing inline.

| Role | Invoke | Runs as | Writes |
|------|--------|---------|--------|
| spec | `/spec` | in-context skill | SPEC.md (BACKLOG.md via script) |
| pr | `/pr` | in-context skill | GitHub state via gh |
| codereview | `/codereview` | dispatch skill + codereview agent | CODEREVIEW.md, push marker |
| codefix | dispatched by /codereview | agent | source files only |
| security | `/security` | dispatch skill + security agent | SECURITY.md |
| tester | `/tester [design]` | dispatch skill + tester agent | TESTING.md (BACKLOG.md via script) |
| architect | `/architect [focus]` | dispatch skill + architect agent | nothing (advisory) |

The review cycle, orchestrated by the `/codereview` skill:

1. Codereview agent (initial mode): reviews the full diff against the push
   base, runs the test baseline, writes a preliminary CODEREVIEW.md, reports
   the security scope needed. Never writes the push marker.
2. Security agent: scans at the reported scope, writes SECURITY.md. Skipped
   when a prior scan still covers the surface.
3. If findings exist: codefix agent (fresh context, reads the findings on disk
   as its spec, applies minimal fixes, never evaluates its own work), then
   codereview agent again in verify mode. At most three fix cycles.
4. Codereview agent (verify mode): confirms security freshness and resolution,
   re-runs tests, and only then writes the push marker and the final entry.

The reviewer's tool list excludes edit and write, and the dispatch layer
refuses to route edits through it; the fixer edits but is forbidden from
judging its own fixes. The exclusion is friction, not physics: shell remains
a write primitive (the reviewer needs it for git, tests, and the marker), so
the operative controls are the never-fix prompt and verify mode re-reviewing
whatever changed. An agent that fixes its own findings is biased toward
confirming the fix worked, so the roles never collapse into one context.

## The pre-push gate

The one hard enforcement point: a `preToolUse` hook that intercepts `git push`
and denies it unless `/codereview` has passed for the exact diff being pushed.

Mechanics:

- On a clean review, the codereview agent (verify mode) records a 16-hex hash
  of the diff against the push base (upstream, else `origin/<branch>`, else
  the empty tree for a first push), excluding the four review artifacts.
- The hook recomputes the hash at push time via the same script
  (`bin/codereview-marker`; one implementation, no drift) and compares.
- Match: the push is allowed. The marker survives failed pushes and commits
  that do not change the diff; it dies the moment any reviewed byte changes.
- No match: the push is denied with an instruction to run `/codereview` now.
  Tag-only pushes and repos with nothing to review pass through.

The gate is content-addressed, not time- or commit-addressed: there is no
window to race and nothing to expire. A first push (no upstream) hashes the
entire tree, so the largest review is also the one the gate insists on.

**Bypass.** When you genuinely need to push unreviewed (you, unprompted; the
model is instructed never to suggest it): run `codereview-skip`, then
`git push`, as two separate commands. The combined form is blocked by design:
the gate inspects the whole command before anything runs, when the skip marker
does not exist yet. The bypass is one-shot and consumed on use.

**Honest residual risks** (inherited from the hook runtime, documented in
[hooks/README.md](hooks/README.md)): hook timeouts fail open, so the gate
script is kept fast and simple; and the CLI overrides any hook after 8
consecutive denials. Neither weakens the routine path, where the first denial
routes straight into `/codereview`.

## Severity model

All review roles share one vocabulary:

| Level | Meaning | Gates push? | Handling |
|-------|---------|-------------|----------|
| BLOCK | Must fix before pushing | Yes | Auto-fixed by the codefix agent |
| WARN | Should fix; significant gap | No | Auto-fixed by the codefix agent |
| NOTE | Informational | No | Reported only, never auto-fixed |

Only BLOCK gates the push. The architect reports on a separate advisory scale
(HEALTHY / WATCH / ACT) because strategy is not a defect list.

## Persistent review files

Four roles write per-project files to the project root. These files are
working state, not documentation: they are the inter-session memory that lets
a fresh session pick up where the last one stopped, and the interface through
which roles read each other's conclusions without sharing a context window.
Each ends with a structured metadata footer (e.g. `<!-- REVIEW_META: {...} -->`)
that the other roles parse.

| File | Written by | Contents |
|------|-----------|----------|
| SPEC.md | /spec | Goal, acceptance criteria, context, turn proposal |
| CODEREVIEW.md | codereview agent | Findings, fixes applied, accepted risks |
| SECURITY.md | security agent | Findings with attack vectors, accepted risks |
| TESTING.md | tester agent | Strategy audit above the durable contract H1 |
| BACKLOG.md | script only | Deferred proposals with revisit criteria |

Accepted Risks sections are the human override channel: a finding moved there
is reported as NOTE thereafter instead of re-blocking every review. BACKLOG.md
is only ever mutated by `bin/spec-backlog-apply.sh` from a manifest, never by
direct model edits; deterministic mutation is what keeps a register that
survives dozens of turns from silently rotting.

## Cross-skill context graph

Roles read each other's persistent files to share context:

```
spec        reads CODEREVIEW, TESTING, BACKLOG      writes SPEC, (BACKLOG)
codereview  reads SPEC, SECURITY, TESTING, CODEREVIEW   writes CODEREVIEW, marker
security    reads SPEC, CODEREVIEW, SECURITY            writes SECURITY
codefix     reads CODEREVIEW, SECURITY                  writes source only
tester      reads SPEC, SECURITY, CODEREVIEW, TESTING   writes TESTING, (BACKLOG)
pr          reads all four META footers                 writes GitHub state
architect   reads all four                              writes nothing
```

The graph has cycles (spec reads CODEREVIEW.md while codereview reads
SPEC.md), but amplification is bounded by three mechanisms: scoped reads (most
recent entry, unresolved BLOCKs, and metadata footers, not full history),
terminal nodes (architect and pr feed human decisions, not automated loops),
and independent severity assessment (each role judges from its own analysis
rather than inheriting another's findings).

## Implement-phase autonomy

The implement phase (turn loop step 3) has a dial:

- **Interactive** (default): you drive, the model implements, you steer
  between steps. Best while criteria are still being discovered.
- **Autopilot**: flip modes (Shift+Tab) and hand it SPEC.md as the brief. The
  acceptance criteria bound the work; the gate bounds the exit. Use when the
  spec is strong and the risk is low. Autopilot approval can loosen the CLI's
  sandbox for the session; know that before you flip it.
- **Parallel agents** (`/fleet`) are deliberately not part of the loop yet:
  fleet subagents share one filesystem without locking, so concurrent writers
  can silently lose work. Tracked in BACKLOG.md until isolation exists.

Whatever the dial, the sequence is fixed: the spec exists before
implementation starts, and the gate runs before anything reaches the remote.

**Model choice.** There is no per-role reasoning-effort control in this
harness. Pick a strong reasoning model for the session (`/model`), set the
plan-mode model with `/model plan`, and rely on the explicit pressure-test
steps built into spec, codereview, security, tester, and architect; they force
the deliberate second pass that effort knobs otherwise buy.

## Coding practices

These bullets are mirrored verbatim from the global instructions
(`copilot/global-copilot-instructions.md`); edit both together.

- Work in small, committable increments. Get one thing working before adding the next.
  Do not build scaffolding for features that are not needed yet.
- Before implementing changes, verify the project builds and existing tests pass.
  Fix pre-existing failures before adding new work.
- When adding or changing functionality, write or update tests in the same increment.
  If the project has no test infrastructure, add a minimal test runner first.
- Run the test suite (or the relevant subset) after each functional change.
  Do not stack multiple untested changes.
- When fixing a bug, change only what is necessary. Do not refactor surrounding code
  or improve unrelated code in the same change.
- If a change causes previously passing tests to fail, revert it and try a different
  approach. Do not modify tests to accommodate a regression.
- If two consecutive fix attempts fail, stop, revert to the last working state, and
  re-evaluate the approach.
- Before switching tasks or when context grows large, write key decisions and current
  state to a file (commit message, README, or project-specific doc). Prefer restarting
  with a written plan over continuing with a long, stale context.
- Do not push, open PRs, or modify remote state unless explicitly asked. Committing
  is local and reversible; pushing is a shared-state action for the user to decide.

## Philosophy

**Verification over control.** The system invests in checking outcomes
(acceptance criteria, adversarial review, content-addressed gating) rather
than controlling how the model implements. Implementation instructions age
badly as models improve; verification contracts do not. This is the bitter
lesson applied to harness design.

**Two kinds of enforcement.** One safety property is enforced by code: the
pre-push hook denies pushes without a matching diff hash. Everything else is
prompt-enforced, some of it backed by structural friction: the reviewer's
tool list excludes the edit and write tools, but shell remains a write
primitive by necessity, so that boundary is friction, not prevention (live
validation confirmed a directly instructed agent will write through shell).
The 3-cycle fix limit, "never fix code yourself," and the finding format
contract are prompt-only. Prompt-enforced properties are non-deterministic;
the LLM usually follows them, but compliance is not guaranteed. This is a deliberate
trade-off. Hard-coding every constraint would make the system rigid. Instead:
hard gates for irreversible actions (pushing code), prompt instructions for
everything else, and structural tests (`tests/lint-skills.sh`) that verify the
contracts between prompted and hard-coded components have not drifted apart.
When adding a constraint, ask: what is the cost of the LLM not following this
instruction? "Code reaches the remote unchecked" needs a hard gate. "A finding
gets mis-categorized" needs a prompt line and a lint check.

**Prompts must earn their keep.** Every instruction competes for the model's
attention with every other instruction; compliance with any single rule drops
as the count grows. When adding or maintaining a prompt, ask two questions:
what model behavior is this supposed to change, and how would I know if it's
working? Instructions that cannot answer both are the first to delete.

**Spec is code.** A spec is not documentation. It is the verification contract
that defines what done looks like. A well-written acceptance criterion is
worth more than a well-written prompt, because it tells the agent (and the
review loop) what to verify.

**Clean context is a mechanism, not a vibe.** Role separation works because
the reviewer genuinely starts empty and reads the diff cold, and the fixer
genuinely reads findings as a spec rather than defending its own output. When
a harness cannot provide isolation, prompting "be adversarial" does not
substitute; the bias lives in the context, not the instructions.

**Artifacts are the memory.** Sessions end; SPEC.md, CODEREVIEW.md,
SECURITY.md, TESTING.md, and BACKLOG.md persist. Roles coordinate through
files with pinned formats, which is why a fresh session (or a different
harness) can pick up mid-project without a handoff conversation.

**Improvements flow upstream.** The skills, agents, and hooks are symlinked
from this repo into the machine. When a downstream project reveals a prompt
gap or a convention worth changing, the fix lands here, never as a local patch
in the downstream project.

## Anti-patterns

Named failure modes this system is built to avoid, each with its countermeasure:

- **False positive factories.** Review prompts that reward finding something.
  Countermeasure: precision over recall, the 80% confidence floor, and "an
  empty report is valid" in every review role.
- **Self-review blindness.** The context that wrote the code reviewing it.
  Countermeasure: isolated review agents; the dispatch skills refuse to review
  inline even as a fallback.
- **Auto-fix oscillation.** Fix loops that thrash or run unbounded.
  Countermeasure: the 3-cycle cap, the 20-line fix skip, syntax-check-and-revert,
  and "requires manual intervention" as a first-class outcome.
- **Circular amplification.** Roles inheriting each other's findings until
  severity inflates. Countermeasure: scoped reads, terminal advisory nodes,
  independent severity assessment, and human-gated Accepted Risks.
- **Stale context poisoning.** Acting on remembered state instead of current
  state. Countermeasure: every loop decision reads META footers from disk;
  agents ground in files and git, never conversation memory.
- **Spec-less loops.** Autonomous iteration without a definition of done.
  Countermeasure: spec-first strict; the plan-approval build shortcut is
  deliberately unused.
- **Context loss at turn boundaries.** Ending a session and losing the thread.
  Countermeasure: turn-close proposals written into SPEC.md; starting sessions
  with `/spec`.
- **Placeholder implementations.** Criteria "met" by stubs. Countermeasure:
  criteria must be independently verifiable; evolve mode checks the codebase,
  not the conversation; spec alignment is a review dimension.
- **Regression snowballing.** Fixes that break earlier work unnoticed.
  Countermeasure: test baseline recorded at initial review, re-run at verify;
  a regressed suite fails the cycle regardless of findings.
- **Silent gate erosion.** Enforcement wording and prompt wording drifting
  apart until the gate means nothing. Countermeasure: the structural lint pins
  every cross-file contract string; wording changes fail the suite.
- **Local patching of shared conventions.** Fixing a shared skill's behavior
  inside one project. Countermeasure: the shared-system boundary in the global
  instructions; fixes flow upstream to this repo.

## Validating on a new machine

Everything deterministic is covered by `bash tests/run-all.sh` (six hundred
plus checks: behavior suites for the gate, marker, backlog script, and
installer, plus the structural lint). Behaviors that depend on the live CLI
(skill discovery, agent isolation, hook wire format, plan handoff) are
enumerated as an ordered checklist in
[docs/mac-validation.md](docs/mac-validation.md); walk it once per new
machine or after a major CLI update.

## References

- [The Bitter Lesson of Agentic Coding](https://agent-hypervisor.ai/posts/bitter-lesson-of-agentic-coding/)
  (Zatloukal, 2026). The design philosophy behind this environment: invest in
  verification and goal-setting, not implementation control.
- [The Curse of Instructions](https://openreview.net/forum?id=R6q67CDBCH)
  (ICLR 2026). Why compliance with any single instruction drops as instruction
  count grows; the argument behind "prompts must earn their keep."
- [GitHub Copilot CLI documentation](https://docs.github.com/en/copilot/concepts/agents/about-copilot-cli).

---

## Differences from zat.env

zatpilot.env is a hard fork of [zat.env](https://github.com/peterzat/zat.env),
the original Claude Code environment by the same author. It stands alone: no
file here references the zat.env repo at runtime, and neither install touches
the other (they target different harness directories and separate marker
caches, so both can live on one machine). The philosophy, the turn loop, the
artifact formats, and the gate semantics are the same system; what changed is
how each concept binds to the harness.

| Concept | zat.env (Claude Code) | zatpilot.env (Copilot CLI) |
|---------|----------------------|----------------------------|
| Role isolation | `context: fork` frontmatter forks every skill; `allowed-tools` caps each fork | Custom agents with isolated context windows and `tools:` caps; thin dispatch skills preserve the slash surface |
| Review pipeline | One codereview fork chains /security and /codefix internally | The /codereview skill orchestrates sibling agent dispatches; the codereview agent gains initial/verify modes so the marker is only written after the security scan reports |
| Codefix input | CODEREVIEW.md only (security findings pre-merged) | CODEREVIEW.md and SECURITY.md (sibling dispatch order means both may hold findings at fix time) |
| Plan handoff | Plan files in `~/.claude/plans/<slug>.md`; a hook reminds `/spec plan` after plan mode exits | `/spec plan` adopts the approved plan from the conversation; confirmed session-store fallback; no slugs |
| Reasoning depth | `effort: max` frontmatter per skill | No per-role effort control; `/model` choice plus explicit pressure-test steps carry the load |
| Gate delivery | PreToolUse hook, exit 2 blocks, stderr coaches the model | preToolUse hook, decision JSON on stdout, deny reason coaches the model; timeouts fail open and 8 consecutive denials end the turn (documented residual risks) |
| Marker cache | `~/.cache/claude-codereview/` | `~/.cache/copilot-codereview/` (disjoint on purpose; independent gates per harness) |
| REVIEW_META | date, commit, reviewed_up_to, base, tier, counts | Same, plus `diff_hash` (verify short-circuit) and `tests_pass`/`tests_fail` (regression baseline across sibling dispatches) |
| External reviewers | Multi-provider fan-out (`review-external.sh`) inside codereview | Not ported; tracked in BACKLOG.md |
| Permissions baseline | Installer writes a clean-slate allow/deny list into settings | Not ported (the CLI owns its JSONC settings); approvals stay interactive; tracked in BACKLOG.md |
| Small utilities | venv auto-approve hook, plan-exit reminder hook, tmux helper, fixed-reasoning launcher | Dropped; the plan-exit reminder became a convention in the global instructions |

What did not change: SPEC.md, CODEREVIEW.md, SECURITY.md, TESTING.md, and
BACKLOG.md formats (a project can move between the two environments and the
artifacts still parse), the severity model, the BLOCK-only gate, the
content-addressed marker, the backlog mutation script, the writing style, and
the test-first porting discipline (the detection suite that hardened zat.env's
gate runs here against the new wire format).

## License

Apache 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
