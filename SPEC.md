## Spec - 2026-09-21 - Windows 11 support

**Goal:** Make zatpilot.env install and enforce correctly on Windows 11, so a
Windows machine gets the same turn loop and the same hard pre-push gate as
macOS and Linux, with the platform's silent failure modes closed rather than
documented around.

### Acceptance Criteria

- [x] The installer detects its platform and, on Windows, wires `~/.copilot`
  with native symlinks (`MSYS=winsymlinks:nativestrict`), printing the link
  mode it chose so a degraded install is never a surprise
  (tests/test-install.sh).
- [ ] The junction-and-copy fallback produces a working install on a Windows
  account that may not create symbolic links, and says that re-running is
  required after a pull.
- [x] The gate hook is registered with a `powershell` entry on Windows as
  well as a `bash` one, and the install test fails a registration that
  carries only `bash`. A bash-only entry never fires there, which would
  leave the gate absent with no error.
- [x] Push detection gates a push wrapped for another shell
  (`bash -lc "git push"`, `pwsh -Command`, `cmd /c`) and quoted arguments,
  while `echo "git push"` and a commit message naming a push still pass
  through (tests/test-pre-push-hook.sh).
- [x] The hook finds the command in the payload when it does not arrive
  under `.command`, over-gating rather than abstaining, so a change in the
  CLI's payload shape cannot silently open the gate.
- [x] The three helpers are invocable by bare name from PowerShell through
  generated `.cmd` shims, and no helper carries a `.sh` extension, which
  PATHEXT does not cover.
- [x] `.gitattributes` pins LF and no file is stored with CRLF, so a Windows
  checkout cannot produce a script with a carriage return in its shebang or
  its heredoc delimiters.
- [x] The marker directory is private on Windows through an NTFS ACL applied
  by the installer, and the marker suite asserts the ACL there and the 0700
  mode elsewhere.
- [x] `tests/run-all.sh` passes in full on Windows under Git Bash.
- [x] The global instructions tell the model how to bridge PowerShell and
  bash, including that POSIX snippets go to `bash -lc` or a `.sh` file.
- [x] README documents the Windows prerequisites, including that Developer
  Mode is what makes the install live, and `docs/windows-validation.md`
  enumerates the checks that need a running CLI.
- [ ] `docs/windows-validation.md` walked end to end on a Windows machine,
  with the CLI version recorded in the commit message.

### Context

Ported on Windows 11 Pro for Workstations (ARM64) with Copilot CLI 1.0.86,
Git for Windows 2.x, jq 1.8.2, and PowerShell 7.6.6. Items 1, 3, 6, and the
skill and instruction discovery paths were confirmed against the live CLI
during the port; the remaining validation items still need a full session.

Four Windows behaviors drove the work, and all four fail silently rather
than loudly, which is why each got a lint pin as well as a test:

- Copilot CLI's shell tool on Windows is PowerShell, named `powershell` in
  hook payloads, with no supported way to select Git Bash. Anything the
  model runs is PowerShell, so POSIX snippets have to be handed to bash
  explicitly and helpers need `.cmd` shims.
- Hook commands are platform-exclusive. The `bash` field never runs on
  Windows.
- Without Developer Mode, MSYS turns `ln -s` into a file copy and prints
  nothing, so the install looks correct and stops tracking the repo.
- MSYS rewrites POSIX-looking argv on the way into a native Windows program.
  This was the subtle one: it made the installer's `include.path` guard
  compare a path git never stored (a duplicate include on every re-run), and
  it silently rewrote the commands the hook test harness thought it was
  testing. Values that matter now go over stdin or through an explicit
  `cygpath -m`.

`bin/spec-backlog-apply.sh` was renamed to `bin/spec-backlog-apply` because
PowerShell hands a `.sh` name to the Windows file association instead of
running it.

---
*Prior spec (2026-08-04): Copilot CLI port of the zat.env environment, 11 of
11 criteria met and validated live on macOS with CLI 1.0.78.*

<!-- SPEC_META: {"date":"2026-09-21","title":"Windows 11 support","criteria_total":12,"criteria_met":10} -->
