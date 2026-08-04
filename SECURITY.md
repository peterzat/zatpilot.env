## Security Review — 2026-08-04 (scope: paths)

**Summary:** Path-scoped review of the pre-push gate hook and its two test
suites at commit 27e5c81, following the same-day full audit and fix cycle.
The two prior WARN bypasses (transparent prefixes, version-like branch
refspecs) are confirmed fixed and regression-tested (86 hook checks and 446
lint checks pass). No injection, secret, or data-exposure issues: the guarded
command string is parsed with jq and used only as data, decisions are emitted
via `jq --arg`, and history scans of all three files are clean. One WARN
remains in the same class as the fixed prefix bypass, plus two NOTEs.

### Threat model note

Unchanged from the prior entry: the gate is a self-discipline control on
agent-issued pushes, not an authentication boundary. Documented outs exist
(`codereview-skip`, plain-terminal pushes, `codereview-marker write`).
Findings below concern silent bypass on realistic non-adversarial input.

### Findings

[WARN] hooks/pre-push-codereview.sh:117-126 — Process wrappers outside the
transparent-prefix allowlist still hide a push from the gate, most plausibly
`timeout`.
  Attack vector: The CLI agent runs `timeout 60 git push` (wrapping a
  possibly-hanging network command in a timeout is a routine agent pattern)
  with an unreviewed diff. The command-position back-walk from `git` hits the
  duration token `60`, which is not an operator, allowlisted prefix word,
  assignment, or `-option`, so `cmdpos=0` and the hook abstains; the push
  proceeds unreviewed. Reproduced against the current functions: `timeout 60
  git push`, `nice git push`, `nice -n 10 git push`, `setsid git push`, and
  `stdbuf -oL git push` are all MISSED, while the fixed forms (`GIT_TRACE=1
  git push`, `env git push`) correctly gate.
  Evidence: hooks/pre-push-codereview.sh:120 allowlists only
  env/command/exec/nohup/time/sudo/builtin/xargs. Arg-taking wrappers cannot
  be fixed by extending the list alone: the back-walk sees the wrapper's
  argument (`60`, `10`) before the wrapper name. Adjacent quoting-class
  variants (`bash -c "git push"`, `eval git push`) are also missed, but those
  are adversarial-tier per the threat model; the header's limitation note
  (lines 67-69) currently documents only quoted paths, not quoted
  invocations.
  Remediation: In the back-walk, also skip bare numeric/duration tokens when
  the preceding word is a known arg-taking wrapper (timeout, nice, nohup,
  stdbuf, setsid, ionice), or flip the residual bias: treat any `git ... push`
  token subsequence as reviewable unless preceded by a clearly word-consuming
  command (the stated bias is over-detection, and a false positive only costs
  a needless review). Add regression cases for `timeout 60 git push` and
  `nice git push`, and extend the header limitation note to cover quoted
  invocations.

[NOTE] hooks/pre-push-codereview.sh:199-211 — A branch named exactly like a
version tag (`v2`, `v1.2`) is presumed a tag and skips the gate.
  Attack vector: In a repo that keeps a maintenance branch named `v2` (common
  in library repos), the agent runs `git push origin v2` with an unreviewed
  diff; the anchored version pattern classifies the refspec as a tag and the
  hook abstains. Reproduced: `git push origin v2` and `git push origin v1.2`
  return tag-only against the current functions. This is the documented
  residual of the accepted 6d87890 fix (the code comment at lines 200-205 and
  CODEREVIEW.md record the trade-off), so it is rated NOTE, not a re-opened
  WARN.
  Evidence: hooks/pre-push-codereview.sh:208 pattern-matches refspecs without
  consulting the repository; the repo-existence check at line 277 runs after
  the tag-only check at line 271, so ground truth is available but unused.
  Remediation: Move the repo check ahead of the tag-only check (outside a
  repo the hook abstains anyway) and resolve each refspec with `git show-ref
  --verify refs/tags/<r>`; fall back to the pattern only if the ref does not
  exist locally. Alternatively record this residual under Accepted Risks.

[NOTE] tests/test-pre-push-hook.sh:131 — Hardcoded developer home path in a
committed test string. Carried forward unresolved from the prior review
(same evidence and severity): the literal `git -C /home/peter/src push` is
detection-fixture data only, functionally harmless, but embeds a real
username in a committed file. Remediation: replace with a neutral path such
as `/tmp/x`, or record under Accepted Risks alongside the author-attribution
item.

### Accepted Risks

Carried forward from the prior review; all remain applicable.

- Hook timeouts fail open (the CLI proceeds as if allowed if the hook exceeds
  `timeoutSec`). Documented in hooks/README.md and README.md; the script is
  kept fast and network-free to stay well under the 30s budget.
- The CLI overrides the hook after 8 consecutive deny decisions. Documented in
  hooks/README.md; the deny reason routes the model into `/codereview` on the
  first block so a compliant session never approaches the limit.
- The gate guards only pushes issued through the CLI agent's shell tool, not
  pushes from a plain terminal, and the one-shot `codereview-skip` bypass
  exists by design. This is the intended scope of a discipline gate.
- Author attribution (name, GitHub URLs, copyright) in LICENSE, NOTICE, and
  README is intentional authorship metadata in the author's own repository, not
  accidental PII. Test placeholders use `test@test.invalid` / `test@example`.

---
*Prior review (2026-08-04, scope: full, commit d316277): full-repository
audit found no secret leaks or injection; two WARN gate bypasses in push
detection (v-prefixed branch refspecs treated as tags, transparent prefixes
hiding the git token) plus a hardcoded-path NOTE. Both WARNs were fixed and
regression-tested in 6d87890.*

<!-- SECURITY_META: {"date":"2026-08-04","commit":"27e5c81d941734456d5a6bacc6eb6304bd9e667f","scope":"paths","scanned_files":["hooks/pre-push-codereview.sh","tests/lint-skills.sh","tests/test-pre-push-hook.sh"],"block":0,"warn":1,"note":2} -->
