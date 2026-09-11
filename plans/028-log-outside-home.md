# Plan 028: Keep the install log out of `$HOME` in dry-run, verify-only and --skip-user-configs

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If any
> STOP condition occurs, stop and report — do not improvise. When done, update
> the status row for this plan in `plans/README.md` (or leave it to the
> reviewer).
>
> **Drift check (run first)**: `git diff --stat e80b564..HEAD -- bin/install-omarchy-quattro.sh README.md`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (same file as plans 021, 027, 031, 032 — execute serially with them)
- **Category**: bug
- **Planned at**: commit `e80b564`, 2026-09-11

## Why this matters

Two documented guarantees are false today: README says `--skip-user-configs`
"keeps the wrapper out of `$HOME` entirely" and `--verify-only` "installs and
changes nothing", yet the wrapper's first three commands after parsing flags
are `mkdir -p`, `touch` and `tee` into
`$HOME/.local/state/omacachy/install-<ts>.log` — unconditionally, including in
`--dry-run`, which the file itself describes as "no state changes". The
fixture suite never sees it because every test run sets `OMACACHY_LOG`.

## Current state

- `bin/install-omarchy-quattro.sh:158-163`:
  ```bash
  LOG_FILE="${OMACACHY_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/omacachy/install-$TIMESTAMP.log}"
  if ! mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || ! touch "$LOG_FILE" 2>/dev/null; then
      LOG_FILE="/tmp/omacachy-install-$TIMESTAMP.log"
      touch "$LOG_FILE"
  fi
  exec > >(tee -a "$LOG_FILE") 2>&1
  ```
- Flags parsed just above (`:141-153`): `$DRY_RUN`, `$VERIFY_ONLY`,
  `$SKIP_USER_CONFIGS`, `$ASSUME_YES`.
- README claims to keep true: search for `out of \`$HOME\` entirely` and
  `installs and changes nothing` (the `--skip-user-configs` and
  `--verify-only` bullets), plus the "**Every run is logged** to
  `~/.local/state/omacachy/install-<timestamp>.log`" paragraph.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `bash -n bin/*.sh bin/lib/*.sh tests/run.sh && shellcheck --severity=warning -x bin/*.sh bin/lib/*.sh tests/run.sh` | exit 0 |
| Fixture suite | `tests/run.sh` | `0 failed` |
| No-$HOME-write check | the before/after file count in Step 2 | equal counts, `/tmp` log path |

## Scope

**In scope**: `bin/install-omarchy-quattro.sh` (the `LOG_FILE` default) and the
one affected README paragraph/bullets.
**Out of scope**: the log format, `start_logging` in `bin/lib/common.sh`, the
failure scanner.

## Git workflow

- Branch: `advisor/028-log-outside-home`
- Commit message, e.g.: `Keep the install log out of $HOME for dry-run, --verify-only and --skip-user-configs`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Pick the log location from the mode

```bash
if $DRY_RUN || $VERIFY_ONLY || $SKIP_USER_CONFIGS; then
    # These modes promise to leave $HOME alone (README) and to change nothing
    # (dry-run contract). Keep the transcript, but outside $HOME.
    LOG_FILE="${OMACACHY_LOG:-/tmp/omacachy-install-$TIMESTAMP.log}"
else
    LOG_FILE="${OMACACHY_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/omacachy/install-$TIMESTAMP.log}"
fi
```

Keep the existing `mkdir -p`/`touch` fallback block below it unchanged (it
still covers the real-install path; `/tmp` needs no `mkdir`).

**Verify**: `bash -n bin/install-omarchy-quattro.sh` → exit 0.

### Step 2: Prove the guarantee on this host

```bash
before=$(find "$HOME/.local/state/omacachy" -type f 2>/dev/null | wc -l)
bin/install-omarchy-quattro.sh --dry-run --yes | sed -n '/^Log:/p'
after=$(find "$HOME/.local/state/omacachy" -type f 2>/dev/null | wc -l)
echo "before=$before after=$after"
```

Expected: the `Log:` line names `/tmp/omacachy-install-<ts>.log`; before ==
after.

**Verify**: as above. (The dev host's existing logs may already be there — the
comparison is about *new* files.)

### Step 3: Make the README match

- In the `--skip-user-configs` bullet, the "keeps the wrapper out of `$HOME`
  entirely" claim now holds — leave it, but add "(its own transcript goes to
  `/tmp`)".
- In the `--verify-only` bullet, "installs and changes nothing" gains the same
  parenthetical.
- In the "**Every run is logged**" paragraph, state: real installs log to
  `~/.local/state/omacachy/install-<timestamp>.log`; `--dry-run`,
  `--verify-only` and `--skip-user-configs` log to
  `/tmp/omacachy-install-<timestamp>.log`.

**Verify**: `grep -n 'omacachy-install' README.md` → the qualified paragraph.

### Step 4: Suite

**Verify**: `tests/run.sh` → `0 failed`; lint gate → exit 0. (Fixtures already
pin `OMACACHY_LOG`, so they are unaffected; confirm the `purity` section still
passes — it asserts no state-changing *binary* runs, and this change removes
one.)

## Test plan

- Step 2 is the acceptance check; capture its output in your report.
- If plan 029 has landed, add a case to its `units`/new section asserting that
  `--dry-run` writes no file under `$HOME/.local/state/omacachy` (same
  before/after pattern, `$WORK`-rooted HOME is not possible — use the real
  `$HOME` and count files, as above, or skip and record why).

## Done criteria

- [ ] `--dry-run`, `--verify-only` and `--skip-user-configs` create no file
      under `$HOME/.local/state/omacachy` — demonstrated by Step 2
- [ ] A real (non-flag) run still logs to `$HOME/.local/state/omacachy` (reason
      from the code; no need to run a real install)
- [ ] `OMACACHY_LOG` still overrides both paths
- [ ] README paragraphs updated
- [ ] Lint gate exit 0; `tests/run.sh` `0 failed`
- [ ] `plans/README.md` status row updated

## STOP conditions

- Another component reads `LOG_FILE` expecting it under `$HOME` (grep
  `LOG_FILE` in the wrapper; the failure scanner prints it, nothing reads it
  back).
- The code no longer matches the excerpts (drift).

## Maintenance notes

- If a future mode is added, decide its log location in the same `if` above —
  do not add another default.
- Reviewer: confirm `/tmp` logs are still world-readable only by the user
  (default umask; `touch` creates 0644 — acceptable for an install transcript,
  but flag it if the log ever starts including secrets; the wrapper prints
  command lines only, which is the same exposure the terminal has).
