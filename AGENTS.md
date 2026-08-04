# AGENTS.md

Conventions for developing the zatpilot.env repo itself. README.md is for
downstream users: how the system works, the design philosophy, what to expect.
This file is for sessions that modify this repo: what to check, what must stay
in sync, how to test. They serve different purposes and should not repeat each
other.

## Inventory

| Path | Contents |
|------|----------|
| `copilot/global-copilot-instructions.md` | Global conventions, symlinked to `~/.copilot/copilot-instructions.md` |
| `copilot/skills/*/SKILL.md` | Six skills: spec, pr (full), codereview, security, tester, architect (trampolines) |
| `copilot/agents/*.agent.md` | Five isolated-context agents: codereview, codefix, security, tester, architect |
| `bin/` | codereview-marker, codereview-skip, spec-backlog-apply.sh |
| `hooks/` | The pre-push gate hook and its documentation |
| `gitconfig/` | Git aliases and the global ignore file |
| `tests/` | Structural lint plus behavior suites; `run-all.sh` runs everything |
| `zatpilot.env-install.sh` | Idempotent installer |
| `docs/mac-validation.md` | Checks that can only run on a machine with the CLI installed |

## Working rules by file type

- **Shell scripts** (`bin/`, `hooks/`, installer): `set -euo pipefail`,
  idempotent where they mutate state, exec bits committed. The hook's decision
  contract is documented in `hooks/README.md`; change hook behavior and that
  document together.
- **Skill files**: self-contained prompt; YAML frontmatter (`name`,
  `description`) then Markdown body. `name` must equal the directory name.
  Skills must be self-sufficient: they gather their own information and never
  assume conversation state beyond the invocation text. Keep each SKILL.md
  under ~500 lines.
- **Agent files**: YAML frontmatter (`description`, `tools`) then Markdown
  body. Agents start with an empty context by design; every step that needs
  state must read it from files or git. The `tools` line is a lint-enforced
  boundary: codereview must not carry edit or write; codefix carries edit but
  not write.

## Contract points that must stay in sync

Each of these is pinned by `tests/lint-skills.sh`. When you add, move, or
reword one side of a contract, update the other side and the lint in the same
increment.

- **Marker single-sourcing.** `bin/codereview-marker` owns the cache dir,
  project hash, base resolution, and diff hash. The hook, `codereview-skip`,
  and the codereview agent invoke it bare-name (the hook also self-locates it
  via its sibling `../bin/` so enforcement never depends on PATH). No inline
  reimplementations.
- **Gate wording.** The gate is BLOCK-only. The hook's deny reason, the
  codereview agent's marker conditions, and README's severity table must agree.
  The bypass is always described as two separate commands.
- **Dispatch modes.** The codereview agent's `initial` and `verify` mode names
  and the marker-authority rule (verify only, after security freshness) are
  shared between the agent and the /codereview skill's orchestration.
- **`Security scope needed:` line.** Produced by the codereview agent
  (initial mode), consumed by the /codereview skill. Exact prefix.
- **META footers.** REVIEW_META (including `diff_hash`, `tests_pass`,
  `tests_fail`), SECURITY_META (including `scanned_files`), TESTING_META, and
  SPEC_META field names are read by grep/sed in other prompts (refresh
  detection, verify short-circuit, pr merge gate). Renaming a field is a
  multi-file change.
- **BACKLOG manifest grammar.** The ops (`delete:`, `adopt:`,
  `purge-origin:`, `append:`/`end-append`) and output lines (`DELETED:`,
  `ANNOTATED:`, `PURGED:`, `APPENDED:`, `SKIPPED:`, `MISS`) are implemented by
  `bin/spec-backlog-apply.sh` and documented in the spec skill and tester
  agent. All BACKLOG.md mutations go through the script.
- **Tester design contract.** The exact H1 `# Durable test-architecture
  contract`, the `tester design YYYY-MM-DD` Origin prefix, and the
  `## Pre-apply checklist` heading are cross-file strings.
- **Coding Practices block.** The bullet list in
  `copilot/global-copilot-instructions.md` is mirrored verbatim in README.md.
  Edit both together.

## How to test

```bash
bash tests/run-all.sh
```

Runs the structural lint plus every `test-*.sh` suite and prints a combined
summary. Each suite's last line is `All N checks passed.` or
`N of M checks failed.`; the runner scrapes those lines, so keep the format.
Run the full suite after any functional change; run the relevant single suite
during iteration.

## Portability rules

Everything must run on stock macOS (BSD userland) and Linux:

- No PCRE grep (the `-P` flag family). Use `sed -n 's/.../p'` extractions.
- No `md5sum`. No bare `sha256sum`; hashing goes through the
  `sha256sum`-or-`shasum -a 256` wrapper pattern.
- No `stat -c` without a `stat -f` fallback. No coreutils `timeout`.
- Guard empty-array expansions (`${arr[@]+"${arr[@]}"}`): macOS `/bin/bash`
  is 3.2 and treats empty arrays as unset under `set -u`.
- Shebang is `#!/usr/bin/env bash` everywhere.

These rules apply to prompt files too: shell snippets inside skills and agents
execute at runtime on the Mac.

## Writing style

Follow the Writing Style section of
`copilot/global-copilot-instructions.md` in every file: no em-dashes, no emoji
or decorative glyphs, `- [ ]` checkboxes only in SPEC.md acceptance criteria.
The lint sweeps for violations.

## What NOT to put here

Downstream usage instructions (README.md's job), machine-specific values, or
session-specific state. Durable decisions go in commit messages or README.md.
