# Live-CLI validation checklist: Windows

Everything deterministic is covered by `bash tests/run-all.sh`. The behaviors
below depend on the live Copilot CLI and its runtime, so they can only be
confirmed on a machine with the CLI installed. Walk the list in order on a
new Windows machine, after a major CLI update, or when the pinned
assumptions in hooks/README.md look stale. Where observed behavior differs
from the expected outcome, fix the named file and update the corresponding
lint pin in the same change.

This is the Windows counterpart to docs/mac-validation.md. Items 1 to 5 are
the ones that do not exist on the Unix platforms; the rest mirror the Mac
list and are included because their failure modes differ here.

## Why Windows needs its own list

Four differences change how the system is wired, and each one fails quietly
rather than loudly:

- **The CLI's shell tool is PowerShell**, named `powershell` in hook
  payloads. There is no supported way to make it Git Bash. Anything the
  model runs is PowerShell syntax, and POSIX snippets have to be handed to
  bash explicitly.
- **Hook commands are platform-exclusive.** A `bash` entry in the hook JSON
  never runs on Windows. A registration without a `powershell` entry leaves
  the gate absent, and nothing reports it.
- **Symlinks need permission.** Without Developer Mode, MSYS turns `ln -s`
  into a file copy and prints nothing. The install looks like it worked and
  then never picks up a repo edit.
- **Checkouts default to CRLF.** A carriage return in a shebang or a heredoc
  delimiter breaks a script. `.gitattributes` pins LF for this repo.

## Setup

```bash
./zatpilot.env-install.sh     # from Git Bash
```

or, from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\zatpilot.env-install.ps1
```

Open a new terminal afterwards so the PATH changes apply, then make a
scratch repo with a fake upstream for the gate items:

```bash
mkdir -p /tmp/gate-scratch && cd /tmp/gate-scratch && git init -b main
git config core.autocrlf false
git commit --allow-empty -m init && git update-ref refs/remotes/origin/main HEAD
echo change > file.txt && git add file.txt && git commit -m change
```

## Windows-specific items

1. **Link mode is symlink, not copy.** The installer prints `Links:
   symlink`. Confirm the install is live rather than a snapshot:

   ```bash
   ls -la ~/.copilot/skills/ ~/.copilot/agents/ ~/.copilot/copilot-instructions.md
   ```

   Expected: every entry is a symlink into the repo. If it says `Links:
   copy`, Developer Mode is off (Settings > System > For developers); turn
   it on, re-run the installer, and re-check. Copy mode is supported but
   every pull then needs a re-run, so it should be a deliberate choice.

2. **The gate hook is registered for PowerShell.**

   ```bash
   jq . ~/.copilot/hooks/zatpilot-env.json
   ```

   Expected: a `powershell` field alongside `bash`, whose command re-enters
   bash with the absolute path of `hooks/pre-push-codereview.sh`. A
   registration with only `bash` means the gate is silently off on this
   machine. Then confirm the script itself answers over the same wire:

   ```bash
   printf '%s' '{"toolName":"powershell","toolArgs":{"command":"git push"}}' \
     | bash ~/src/zatpilot.env/hooks/pre-push-codereview.sh; echo "exit: $?"
   ```

   Expected inside the scratch repo with no marker: a deny JSON and exit 0.

3. **The real `toolName` and `toolArgs` shape.** The hook matches any tool
   name containing `bash` or `shell`, and reads the command from `.command`,
   then `.script`, then any string in the payload. Confirm what the CLI
   actually sends rather than trusting the docs: add a temporary
   `sessionStart` or `preToolUse` logging hook that dumps stdin to a file,
   run one shell command, and read the payload. Record the observed shape in
   hooks/README.md. If the command arrives under a key the hook does not
   name, the fallback string scan still gates the push, but add the key.

4. **Helpers run by bare name from PowerShell.** In a PowerShell terminal:

   ```powershell
   codereview-marker path
   codereview-skip
   ```

   Expected: the marker path prints, and `codereview-skip` creates the skip
   file. These resolve through the generated `.cmd` shims in
   `~/.copilot/bin`. If PowerShell instead opens a file-association dialog,
   a helper has an extension PATHEXT does not cover; helpers must be
   extensionless.

5. **The marker path agrees across shells.** The gate writes the marker from
   one process and reads it from another, and on Windows those can disagree
   about `HOME`.

   ```bash
   codereview-marker path                     # Git Bash
   ```
   ```powershell
   codereview-marker path                     # PowerShell, via the shim
   ```

   Expected: the same path from both. A mismatch means the gate can never be
   satisfied, because the review writes a marker the hook does not read.

## Items mirrored from the Mac list

6. **Skill discovery through symlinks.** Start `copilot`; run `/skills
   list`. Expected: spec, pr, codereview, security, tester, architect. If
   they are missing, check whether the CLI follows symlinked skill
   directories on Windows; the installer's copy mode is the fallback.

7. **Agent discovery through symlinks.** Run `/agent`. Expected: codereview,
   codefix, security, tester, architect in the picker.

8. **Instructions load.** Start the CLI in `~/src/zatpilot.env` and run
   `copilot instruction list` or `/context`. Expected: the personal
   instructions from `~/.copilot/copilot-instructions.md` plus AGENTS.md,
   each applied once.

9. **Hook fires on push.** In the scratch repo (diff present, no marker),
   ask the CLI to run `git push`. Expected: the push is denied and the
   visible reason contains "Run /codereview now".

10. **Wrapped pushes are gated too.** Ask the CLI to run
    `bash -lc "git push"`. Expected: denied, same as a bare push. This is
    the form the model is most likely to produce on Windows when it needs
    POSIX syntax, and it bypassed the gate before the tokenizer stripped
    quotes.

11. **Allow path and marker.** Run `/codereview` in the scratch repo, let
    the cycle finish clean, then push. Expected: the push proceeds without
    an extra permission prompt and the marker under
    `~/.cache/copilot-codereview/` survives the push.

12. **Hook latency headroom.** In your largest real repo with an unpushed
    diff:

    ```bash
    time (printf '%s' '{"toolName":"powershell","toolArgs":{"command":"git push"}}' \
      | bash ~/src/zatpilot.env/hooks/pre-push-codereview.sh)
    ```

    Expected: well under 30 seconds. Timeouts fail OPEN, so a slow hook is
    an open gate. Windows git is slower than the Unix platforms on large
    diffs, so this matters more here.

13. **POSIX snippets inside prompts.** Run `/spec` through a turn that
    mutates BACKLOG.md. Expected: the model hands the manifest to
    `spec-backlog-apply` through bash rather than trying a PowerShell
    heredoc. If it tries PowerShell syntax and fails, tighten the Windows
    paragraph in `copilot/global-copilot-instructions.md`.

14. **Fix cycle end-to-end.** Introduce a deliberate BLOCK-worthy bug and
    run `/codereview`. Expected: findings written, security scan at the
    reported scope, codefix applies, verify re-reviews, marker written,
    CODEREVIEW.md entry has Fixes Applied populated.

15. **Skip bypass two-command flow.** Say "push now" with an unreviewed
    diff. Expected: `codereview-skip` then `git push` as two separate
    commands, the second succeeds, and the skip marker is gone afterwards.

16. **Headless smoke.** `copilot -p "use the architect agent: focus deps"
    --agent architect` in a small repo. Expected: a focused dependency
    review with the HEALTHY / WATCH / ACT verdict and no file writes.

17. **Full suite under Git Bash.** `bash tests/run-all.sh`. Expected: every
    suite reports all checks passed. The suite is slower here than on the
    Unix platforms because each fixture repo is a real `git init`.

When all items pass, record the CLI version tested (`copilot --version`) and
the Windows build in the commit message that checks off the Windows criteria
in SPEC.md.
