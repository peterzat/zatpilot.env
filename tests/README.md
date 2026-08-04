# Tests

Run everything:

```bash
bash tests/run-all.sh
```

The runner executes `lint-skills.sh` first, then every `test-*.sh` in sorted
order, and prints a combined summary. Contract: each suite's LAST output line
is exactly `All N checks passed.` or `N of M checks failed.`; the runner
scrapes those lines and counts a suite with no summary line as failed.

| Suite | Covers |
|-------|--------|
| `lint-skills.sh` | Structural drift guard: frontmatter, builder/verifier tool boundaries, dispatch-mode and marker-authority contracts, META field parity, gate wording alignment, forbidden strings, BSD/macOS portability, writing style, shellcheck when installed |
| `test-pre-push-hook.sh` | Push detection across command forms (compound, tight-packed, newline, subshell, `git -C`), tag-only scoping, the Copilot decision-JSON contract, wire-format variants, fail-closed paths, PATH-independent marker resolution |
| `test-codereview-marker.sh` | The three base-resolution cases, empty-diff exit 2, hash stability, marker write semantics, 0700 cache dir, parity with an independent reference computation |
| `test-spec-backlog-apply.sh` | Manifest ops (delete, adopt, purge-origin, append), ACTIVE preservation, MISS semantics, file creation, unterminated-block error. Single-op sections double as the bash 3.2 empty-array regression surface |
| `test-install.sh` | Sandboxed-HOME installer run: symlinks, generated hooks JSON, PATH line, idempotent re-run, backup behavior |

Notes:

- Suites are plain bash with a shared hand-rolled pass/fail harness; no
  framework dependency.
- Everything must pass on Linux and macOS. On a Mac, additionally run the
  suites under `/bin/bash` (3.2) to prove the portability guards:
  `for t in tests/test-*.sh; do /bin/bash "$t"; done`
- Runtime behavior that needs the Copilot CLI itself is not testable here;
  see `docs/mac-validation.md`.
