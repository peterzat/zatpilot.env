# Live-CLI validation checklist

Everything deterministic is covered by `bash tests/run-all.sh`. The behaviors
below depend on the live Copilot CLI and its runtime, so they can only be
confirmed on a machine with the CLI installed. Walk the list in order on a new
machine, after a major CLI update, or when the pinned assumptions in
hooks/README.md look stale. Where observed behavior differs from the expected
outcome, fix the named file and update the corresponding lint pin in the same
change.

Setup: run `./zatpilot.env-install.sh`, open a new shell, and use a scratch
git repo with a fake upstream for the gate items:

```bash
mkdir -p /tmp/gate-scratch && cd /tmp/gate-scratch && git init -b main
git commit --allow-empty -m init && git update-ref refs/remotes/origin/main HEAD
echo change > file.txt && git add file.txt && git commit -m change
```

1. **Skill discovery through symlinks.** Start `copilot`; run `/skills list`.
   Expected: spec, pr, codereview, security, tester, architect all listed. If
   missing, the CLI may not follow symlinked skill directories: switch the
   installer's skill loop from `ln -s` to copy mode and re-test.

2. **Agent discovery through symlinks.** Run `/agent`. Expected: codereview,
   codefix, security, tester, architect in the picker. Same copy-mode fallback
   as item 1 if absent.

3. **Agent `tools:` restriction syntax.** In a scratch repo, dispatch the
   codereview agent and ask it (via the dispatch prompt) to modify a file.
   Expected (recorded 2026-08-04, CLI 1.0.78): the dispatch layer refuses to
   route edits through the reviewer, and dispatched reviews never modify
   files; but a direct user instruction to the agent is executed via shell,
   which is in its toolset by necessity. The exclusion removes the edit
   tools, not the ability to write. The boundary is prompt-tier with tool
   friction; README's Two kinds of enforcement section states this.

4. **Hook fires on push.** In the scratch repo (diff present, no marker), ask
   the CLI to run `git push`. Expected: the push is denied and the visible
   reason contains "Run /codereview now". If the hook never fires, check the
   `toolName` the CLI actually sends (add a temporary `sessionStart` hook that
   logs, or consult the hooks reference) and widen the script's toolName
   filter.

5. **Allow path and marker.** Run `/codereview` in the scratch repo, let the
   cycle finish clean, then push. Expected: the push proceeds without an extra
   permission prompt (allow JSON honored) and the marker file under
   `~/.cache/copilot-codereview/` persists after the push.

6. **Hook latency headroom.** In your largest real repo with an unpushed diff:
   `time (printf '%s' "$(jq -n '{toolName:"bash",toolArgs:({command:"git push"}|tostring)}')" | bash ~/src/zatpilot.env/hooks/pre-push-codereview.sh)`.
   Expected: well under 30 seconds (timeouts fail OPEN; a slow hook is an open
   gate). If close, raise `timeoutSec` in the installer and hooks/README.md.

7. **Eight-consecutive-denial override.** Script nine denied pushes in a row
   in the scratch repo. Expected per docs: the CLI overrides the hook and ends
   the turn. Record what actually happens (especially whether the ninth push
   executes) in hooks/README.md.

8. **Sandbox vs marker writes.** With the local sandbox enabled, run a full
   `/codereview` and confirm the verify-mode `codereview-marker write` (to
   `~/.cache`) succeeds or surfaces an approvable prompt. Record any required
   approval in hooks/README.md.

9. **Trampoline dispatch engages agents.** Run `/codereview` and watch the UI.
   Expected: visible subagent activity for the codereview agent (and security
   agent when scoped); the main context does not read the diff itself. If
   naming the agent does not dispatch, use `/agent` or `--agent` and note the
   reliable invocation form inside the three dispatch skills.

10. **Fix cycle end-to-end.** Introduce a deliberate BLOCK-worthy bug, run
    `/codereview`. Expected: initial review writes findings, security scan
    runs at the reported scope, codefix agent fixes, verify mode re-reviews,
    marker written, final CODEREVIEW.md entry has Fixes Applied populated.

11. **Plan handoff from context.** Enter plan mode, approve a small plan,
    choose "exit plan mode and I will prompt myself", run `/spec plan`.
    Expected: SPEC.md written from the plan without asking for it again.

12. **Plan handoff fallback.** In a NEW session (no plan in context), run
    `/spec plan`. Expected (contract updated after the 2026-08-04 walk): it
    finds the newest `~/.copilot/session-state/*/plan.md`, grounds it
    against the repository, and adopts without a round-trip when every file
    the plan names exists here (stating the path and mtime it used); it
    asks for confirmation only when a named file is absent or the match is
    ambiguous. Observed: the unambiguous case adopted cleanly without
    asking.

13. **bash 3.2.** `for t in ~/src/zatpilot.env/tests/test-*.sh; do /bin/bash "$t" | tail -1; done`
    Expected: every suite prints `All N checks passed.` under the stock macOS
    bash.

14. **PATH via zshrc.** Open a fresh terminal. Expected:
    `command -v codereview-marker` resolves to `~/.copilot/bin/`.

15. **Instructions load and dedup.** Start the CLI inside
    `~/src/zatpilot.env` (where CLAUDE.md symlinks to AGENTS.md) and run
    `/context` or ask what instructions are loaded. Expected: the global
    instructions and AGENTS.md apply once each, no duplicated content.

16. **Codefix is not auto-inferred.** With a stale CODEREVIEW.md containing
    findings, say "fix these issues" (without /codereview). Expected: the
    codefix agent is NOT auto-selected; normal editing happens instead. If it
    self-selects, narrow the codefix agent description further.

17. **Skip bypass two-command flow.** Say "push now" with an unreviewed diff.
    Expected: the model runs `codereview-skip`, then `git push` as two
    separate commands; the second succeeds; the skip marker is gone after.

18. **Headless smoke.** `copilot -p "use the architect agent: focus deps" --agent architect`
    in a small repo. Expected: a focused dependency review with the
    HEALTHY / WATCH / ACT verdict, no file writes.

When all items pass, record the CLI version tested (`copilot --version`) in
the commit message that checks off the Mac criteria in SPEC.md.
