## Security Review — 2026-08-04 (scope: full)

**Summary:** Full-repository audit of the zatpilot.env agentic-coding
environment (shell scripts, the pre-push gate hook, installer, skill/agent
prompt files, tests). No secret leaks, injection, or credential exposure found.
Two defense-in-depth gaps in the pre-push gate's push-detection heuristics
allow real code pushes to silently skip the review gate on realistic input.

### Threat model note

The pre-push gate is a Copilot CLI `preToolUse` hook: it fires only for pushes
issued through the CLI agent's shell tool, and its purpose is to keep the agent
from pushing code that has not passed `/codereview`. It is a self-discipline
control, not an authentication boundary. A user (or an adversarial agent) has
trivial documented outs (`codereview-skip`, pushing from a plain terminal,
running `codereview-marker write` directly). The findings below therefore
concern silent bypass on non-adversarial input, which is what erodes a
discipline gate in practice, and are rated WARN accordingly.

### Findings

[WARN] hooks/pre-push-codereview.sh:186-192 — Tag-only heuristic treats any
`v<digit>` refspec as a tag, so pushing a branch whose name starts with `v` and
a digit silently skips the gate.
  Attack vector: The CLI agent runs `git push origin v2feature` (or `v2`,
  `v1.5-hotfix`, `v3-api`, any branch named `v<digit>...`) with an unreviewed
  diff. `is_tag_only_push` classifies the refspec as tag-only via the
  `^v[0-9]` match, the hook abstains, and the code push reaches the remote
  without `/codereview`. Reproduced: `git push origin v2feature` returns
  `abstain` from the hook against a repo with an unpushed diff and no marker.
  Evidence: hooks/pre-push-codereview.sh:191 matches refspecs against
  `^v[0-9]` to decide "looks like a tag." The regex was intended for version
  tags (`v1.2.0`) but also matches branch names. The function's own header
  (lines 141-153) documents that a false positive here SKIPS the gate, and
  this is a false positive on a common branch-naming convention.
  Remediation: Restrict the tag heuristic to explicit tag refspecs
  (`refs/tags/...`), or resolve the refspec against `refs/tags/` in the repo
  before treating it as a tag, rather than pattern-matching `v<digit>`. Add a
  regression case (`git push origin v2feature` must deny when a diff exists).

[WARN] hooks/pre-push-codereview.sh:102-134 — Push detection only treats a
`git` token as a command when it is first or follows a shell operator, so any
prefix word evades the gate.
  Attack vector: The CLI agent runs a prefixed push form with an unreviewed
  diff and the hook abstains. Reproduced against a repo with an unpushed diff
  and no marker: `GIT_TRACE=1 git push`, `env git push`, `command git push`,
  and `nohup git push` all return `abstain` (a bare `git push` correctly
  returns `deny`). `GIT_TRACE=1 git push` is the most likely non-adversarial
  case: adding `GIT_TRACE=1` to debug a failing push is routine, and it
  silently disables the gate.
  Evidence: `_push_subcommand_indices` (lines 102-134) counts a `git` token as
  command-position only if `i == 0` or the previous token matches the operator
  case at lines 110-113. A variable-assignment prefix (`GIT_TRACE=1`) or a
  command wrapper (`env`, `command`, `nohup`, `xargs`, `time`, `sudo`) is not
  an operator, so the following `git` is skipped and no push index is emitted.
  This is the same class of bypass as the `git -C <dir> push` bug the suite was
  built to catch (tests/test-pre-push-hook.sh:287-294); the documented
  limitation at lines 66-69 only covers quoted whitespace paths, not prefixes.
  Remediation: In the command-position check, skip leading `VAR=value`
  assignment tokens and known no-op wrappers (`env`, `command`, `nohup`,
  `time`, `xargs`, `sudo`) before deciding the token is not a command, or treat
  any `git push` subsequence as reviewable (the function's stated bias is
  toward over-detection, since a false positive only costs a needless review).
  Add regression cases for the prefixed forms.

[NOTE] tests/test-pre-push-hook.sh:131 — Hardcoded developer home path in a
committed test string.
  Attack vector: None directly; informational. The literal
  `"git -C /home/peter/src push"` embeds a real local username/path in a test
  input. It is used only as a string to tokenize (the test runs in a scratch
  dir), so it is functionally harmless, but it exposes the username and is
  inconsistent with the repo's portability ethos and the other tests' use of
  `/tmp`.
  Evidence: tests/test-pre-push-hook.sh:131.
  Remediation: Replace with a neutral path such as `/tmp/x` or `/repo`.

### Accepted Risks

The following are documented, intended residual risks of the gate, not new
findings. They are recorded here so future reviews do not re-flag them.

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

<!-- SECURITY_META: {"date":"2026-08-04","commit":"d316277d28f4f0b53fe761554bff7d1427b59eef","scope":"full","block":0,"warn":2,"note":1} -->
