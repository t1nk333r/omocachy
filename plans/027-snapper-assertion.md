# Plan 027: Make the snapper assertion compare something, or say it cannot

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If any
> STOP condition occurs, stop and report — do not improvise. When done, update
> the status row for this plan in `plans/README.md` (or leave it to the
> reviewer).
>
> **Drift check (run first)**: `git diff --stat e80b564..HEAD -- bin/install-omarchy-quattro.sh`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (same file as plans 021, 028, 031, 032 — execute serially with them)
- **Category**: bug
- **Planned at**: commit `e80b564`, 2026-09-11

## Why this matters

`--verify-only` is the mode README tells users to run after every
`omarchy update`, and the suite's snapper assertion is the line that is
supposed to prove Omarchy's `install/config/snapper.sh` did not rewrite
`/etc/snapper/configs/root`. But the check short-circuits to success when the
pre-install backup path is empty — which it always is in `--verify-only`,
where no backup is taken — so the suite prints PASS having compared nothing.
Everything else that cannot run says so loudly ("needs passwordless sudo …
not treated as a failure"); this one silently claims a verification.

## Current state

- `bin/install-omarchy-quattro.sh:574` — `SNAPPER_BACKUP=""` at startup;
  `:1082` sets it on a full run (`backup_etc_file "$SNAPPER_CONFIG" SNAPPER_BACKUP`).
- `:743-745`:
  ```bash
  check_snapper() {
      [[ -z $SNAPPER_BACKUP ]] || cmp -s "$SNAPPER_BACKUP" "$SNAPPER_CONFIG"
  }
  ```
- `:830` registers it: `assert "/etc/snapper/configs/root matches the pre-install backup" check_snapper`
- `:845-853` — `--verify-only` runs the suite and exits with its verdict;
  `backup_etc_file` is where the `*.omarchy-quattro-backup-*` copies land
  (see how the other checks name their subjects, e.g. `check_limine_default`).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `bash -n bin/*.sh bin/lib/*.sh tests/run.sh && shellcheck --severity=warning -x bin/*.sh bin/lib/*.sh tests/run.sh` | exit 0 |
| Fixture suite | `tests/run.sh` | `0 failed` |
| Suite text on this host | `bin/install-omarchy-quattro.sh --verify-only \| sed -n '/snapper/p'` | "matches …" or the explicit no-backup note |

## Scope

**In scope**: `bin/install-omarchy-quattro.sh` (`check_snapper` only).
**Out of scope**: the other checks, `backup_etc_file`, the suite's exit logic.

## Git workflow

- Branch: `advisor/027-snapper-assertion`
- Commit message, e.g.: `Verify the snapper config against a real backup in --verify-only`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Fall back to the newest on-disk backup, else say so

```bash
check_snapper() {
    local backup="$SNAPPER_BACKUP" newest
    if [[ -z $backup ]]; then
        newest="$(ls -1t /etc/snapper/configs/root.omarchy-quattro-backup-* 2>/dev/null | head -n1 || true)"
        if [[ -z $newest ]]; then
            echo "      (no pre-install snapper backup on this machine to compare against; not verified)"
            return 0
        fi
        backup="$newest"
    fi
    cmp -s "$backup" "$SNAPPER_CONFIG"
}
```

Match the file's existing check style (absolute paths, same echo indentation as
`check_ufw_ssh`'s note at `:779`).

**Verify**: `bash -n bin/install-omarchy-quattro.sh` → exit 0;
`sed -n '/check_snapper/,/^}/p' bin/install-omarchy-quattro.sh` shows the
fallback and the note.

### Step 2: Check the message on this host

**Verify**: `bin/install-omarchy-quattro.sh --verify-only 2>&1 | sed -n '/snapper/p'`
→ the line is either a real comparison or the explicit
"(no pre-install snapper backup … not verified)" note. Other checks may FAIL on
this non-CachyOS dev host — that is expected; record which ones in your report.

### Step 3: Regression case in `tests/run.sh`

Add a case that exercises the helper directly by sourcing it is not possible
(the wrapper executes top-level code), so pin the observable text instead: run
`--verify-only` under a fixture sysroot is not supported either — therefore
assert on the source shape (the `check_snapper` body no longer contains
`[[ -z $SNAPPER_BACKUP ]] ||`) with a single `ok`/`bad` in the `matrix` or a
new `suite` section. If plan 029 has landed, put it in its `units` section.

**Verify**: `tests/run.sh` → `0 failed`, including the new case.

## Test plan

- Step 3 pins the fix's shape; Step 2 is the human-visible acceptance.
- The genuinely stronger test — a fixture whose `/etc/snapper/configs/root`
  differs from a bundled backup — needs the assertion suite to be
  sysroot-runnable, which is the deferred item in plan 029's maintenance notes.
  Do not attempt it here.

## Done criteria

- [ ] `check_snapper` never returns success without comparing *something*;
      when nothing is comparable it prints the explicit note
- [ ] The suite line text is unchanged for the real-comparison case
- [ ] Lint gate exit 0; `tests/run.sh` `0 failed`
- [ ] No files outside `bin/install-omarchy-quattro.sh` (plus the one test
      case) are modified
- [ ] `plans/README.md` status row updated

## STOP conditions

- `backup_etc_file` names its copies differently than
  `root.omarchy-quattro-backup-<timestamp>` — derive the real pattern from the
  function and report if it does not match the excerpt.
- The code no longer matches the excerpts (drift).

## Maintenance notes

- Reviewer: the fallback deliberately keeps PASS when no backup exists (there
  is nothing to compare); the note is the honesty signal. Do not turn it into
  a FAIL — half the machines that run `--verify-only` never ran the wrapper.
