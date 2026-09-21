# Global Conventions

This file is symlinked to `~/.copilot/copilot-instructions.md` and applies to
all projects on this machine.

## Git Identity

All commits must be attributed solely to the configured `user.name`. Never add
Co-Authored-By trailers. Identity is set by `zatpilot.env-install.sh` (prompted
on first run, reused from git config on subsequent runs).

## Shared System Boundary

Skills (`~/.copilot/skills/`), agents (`~/.copilot/agents/`), hooks
(`~/.copilot/hooks/`), and this file are symlinked or generated from
`~/src/zatpilot.env/`. Editing them in place from a downstream project modifies
the shared system. When working on any project other than zatpilot.env itself,
do not modify these files. If a skill or agent produces wrong behavior or a
convention needs updating, note the issue and defer the fix to a zatpilot.env
session. Behavioral corrections belong in the skill or agent definition, not in
a per-project file that patches around it.

## Memory

Memory persistence hierarchy, most to least durable:
1. Instructions files (this file, project AGENTS.md) -- conventions, always loaded
2. Skills and agents -- reusable prompts, shared across projects
3. Working documents (SPEC.md, TESTING.md, etc.) -- project state, read on demand
4. Plans and conversations -- current session only

Durable operational facts about a project (required env setup, CI quirks, test
prerequisites) belong in that project's AGENTS.md. Working documents are managed
by their respective skills and agents.

## Plan Mode and the Spec

For non-trivial work, plan first. Enter plan mode (Shift+Tab to cycle modes, or
`/plan`), explore, and approve the plan. At approval choose "exit plan mode and
I will prompt myself", then run `/spec plan` to convert the approved plan into
SPEC.md before any implementation. Do not use the accept-and-build-on-autopilot
shortcut from the plan approval menu: it skips the spec,
and the spec is the contract the review loop verifies against. Autopilot
belongs in the implement phase, driven by SPEC.md, after the spec exists.

## Specification Quality

When editing acceptance criteria outside `/spec`, apply the same pressure-test
rigor the skill uses: what input breaks it, what assumptions are unstated, what
failure behavior is unspecified. Do not remove, reword, or reorder acceptance
criteria in SPEC.md; only check them off when verified.

## Coding Practices

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

## Pre-push review gate

zatpilot.env installs a hook that blocks `git push` until `/codereview` passes.
When it blocks, run `/codereview` automatically. Do not ask the user first or
offer to skip. The bypass is only for when the user says "push now" unprompted;
never suggest it. Run it as two separate commands, `codereview-skip` then
`git push`, not the combined `codereview-skip && git push`: the hook inspects
the whole command before anything runs, when the marker does not exist yet.

## Shell on Windows

On Windows the CLI's shell is PowerShell, and there is no setting that
changes it. Git Bash is installed and is what this environment's scripts,
skills, and agents are written for, so the two have to be bridged
deliberately.

- Write commands in PowerShell syntax by default, as on any Windows machine.
- Any snippet this environment gives you in POSIX form goes to bash, not to
  PowerShell. PowerShell has no heredoc, no `<` input redirection, and
  different quoting, so a POSIX snippet pasted into it fails in ways that
  look like the tool is broken.
- Run a short POSIX snippet as `bash -lc '<snippet>'`. For anything with a
  heredoc, embedded quotes, or more than one line, write it to a `.sh` file
  first and run `bash <file>`; that avoids two layers of quoting.
- The helper scripts (`codereview-marker`, `codereview-skip`,
  `spec-backlog-apply`) are callable by bare name from PowerShell. The
  installer generates `.cmd` shims for them. Do not prefix them with `bash`
  and do not add a `.sh` extension.
- Paths: prefer forward slashes. When a path has to cross into a native
  Windows program, `cygpath -m` converts it. Be aware that MSYS rewrites
  POSIX-looking arguments when it invokes a native program, so a value that
  begins with `/` may not arrive as written.
## Writing Style

When writing human-readable output (commit messages, review findings, explanations,
persistent files like SPEC.md/CODEREVIEW.md/SECURITY.md/TESTING.md, README content):

- Professional, direct, concise. State the point, then support it.
- No AI-voice patterns ("It's important to note that," "Let's," "Great question,"),
  no em-dashes (use commas, periods, or parentheses).
- Never emoji, checkmarks, or other decorative glyphs; `- [x]` task-list checkboxes
  count as decoration. Plain bulleted lists are fine, and completed work reads as
  plain bullets. One exception: SPEC.md acceptance criteria, where checking off is
  the tracking mechanism, not decoration.
- Prefer short declarative sentences. When uncertain, say so plainly.

## Python

- Always use `python3 -m venv .venv` per project. Never `pip install` outside a venv.
- Set `PIP_REQUIRE_VIRTUALENV=true` globally.

## Secrets

`.env` files are globally gitignored. Use environment variables or a secrets
manager. Tailscale-scoped access preferred for internal services.
