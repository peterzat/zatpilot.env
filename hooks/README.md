# Hooks

One hook: the pre-push code review gate. It is the system's single hard
enforcement point, so its mechanics are documented here in full.

## pre-push-codereview.sh

A `preToolUse` hook for the Copilot CLI. Registered by the installer, which
writes `~/.copilot/hooks/zatpilot-env.json` pointing at this script with an
absolute path:

```json
{
  "version": 1,
  "hooks": {
    "preToolUse": [
      {
        "type": "command",
        "bash": "/absolute/path/to/zatpilot.env/hooks/pre-push-codereview.sh",
        "timeoutSec": 30
      }
    ]
  }
}
```

No matcher is set. The script self-filters on `toolName`, so a wrong or
renamed matcher key can never cause a silent bypass; the worst case is the
script running (and instantly exiting) for non-shell tools.

### Wire format

The CLI sends a JSON payload on stdin: `toolName` (e.g. `bash`) and
`toolArgs`, a JSON-encoded string containing the tool input (parsed twice;
an object form is tolerated). The hook answers on stdout with
`{"permissionDecision": "allow"|"deny", "permissionDecisionReason": "..."}`
and exit 0. No output with exit 0 abstains (normal permission handling
applies). Exit 2 is an unconditional deny, reserved for infrastructure
failure.

### Decision contract

| Situation | Decision |
|-----------|----------|
| toolName is not a shell tool | abstain (silent exit 0) |
| Command is not a git push | abstain |
| Tag-only push | abstain (no code content to review) |
| Not inside a git repository | abstain (not our concern) |
| Nothing to review (empty diff vs base) | abstain, note on stderr |
| Skip marker present | allow JSON; marker consumed |
| Marker matches current diff hash | allow JSON; marker kept |
| No valid marker | deny JSON; reason instructs running /codereview |
| jq missing, marker tooling broken, toolArgs unparseable | stderr + exit 2 (fail closed) |

The deny reason is shown to the model. It instructs running /codereview
immediately, forbids offering the bypass, and states the bypass form
(codereview-skip, then git push, as two separate commands).

### Marker flow

```
/codereview passes cleanly
  -> codereview agent (verify mode) runs `codereview-marker write`
  -> marker file holds a 16-hex hash of the diff vs the push base
       (excluding CODEREVIEW.md, SECURITY.md, TESTING.md, SPEC.md)
git push attempted
  -> hook recomputes the hash via the same script
  -> match: allow (marker kept; a failed network push needs no re-review)
  -> mismatch or missing: deny with instructions
codereview-skip
  -> writes a one-shot skip marker; the next push consumes it
```

The marker is content-addressed: it survives commits that do not change the
diff against the base, and it is invalidated the moment any reviewed byte
changes. Markers live in
`${XDG_CACHE_HOME:-~/.cache}/copilot-codereview/` (mode 0700).

### Known caveats of the hook runtime

- **Timeouts fail open.** If the hook exceeds `timeoutSec`, the CLI proceeds
  as if the hook allowed. The script does no network work and one diff-hash
  computation, so it stays far under 30 seconds; an enormous first-push diff
  is the slow case worth watching (docs/mac-validation.md item 6).
- **Consecutive-deny override.** After 8 consecutive deny decisions the CLI
  overrides the hook and ends the turn. The deny reason routes the model to
  /codereview on the first block, so a compliant session never approaches
  the limit. Observed behavior at the limit is a Mac validation item.
- **Sandboxing.** If a local sandbox restricts writes, the marker write from
  the codereview agent (to `~/.cache`) may need approval. Validation item.

### Manual test recipe

```bash
payload=$(jq -n '{toolName: "bash", toolArgs: ({command: "git push"} | tostring)}')
printf '%s' "${payload}" | bash hooks/pre-push-codereview.sh; echo "exit: $?"
```

Run inside a repo with unpushed changes and no marker: expect a deny JSON on
stdout and exit 0. The full behavior matrix lives in
`tests/test-pre-push-hook.sh`.

## Adding a new hook

1. Add the script here, `chmod +x`, `#!/usr/bin/env bash`, `set -euo pipefail`.
2. Extend the installer's hooks-JSON generation to include it.
3. Document it in this file: event, decision contract, failure semantics.
4. Add lint checks in `tests/lint-skills.sh` for any strings other files
   depend on, and a behavior suite if the hook makes decisions.
5. Re-run the installer on each machine.
