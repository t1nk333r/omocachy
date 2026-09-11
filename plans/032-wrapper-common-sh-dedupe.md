# Plan 032: Source `bin/lib/common.sh` from the wrapper and drop the hand-rolled prompt

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If any
> STOP condition occurs, stop and report — do not improvise. When done, update
> the status row for this plan in `plans/README.md` (or leave it to the
> reviewer).
>
> **Drift check (run first)**: `git diff --stat e80b564..HEAD -- bin/install-omarchy-quattro.sh`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans 021, 027, 028, 031 (same file — execute last among them); most valuable after plan 029 (its sections are the regression net)
- **Category**: tech-debt
- **Planned at**: commit `e80b564`, 2026-09-11

## Why this matters

The project's central contract — every state-changing command flows through
`run`/`run_root`/`write_root_file`/`append_root_file`, enforceable with one
grep — is implemented twice: `bin/lib/common.sh:16-60` and a byte-identical
copy at `bin/install-omarchy-quattro.sh:75-111`. The copy has already drifted
in effect: the shared `confirm` auto-answers under `--dry-run`
(`bin/lib/common.sh:90-95`), while the wrapper's hand-rolled non-CachyOS prompt
(`:300-307`) does not, so a plain `--dry-run` on a host without `[cachyos*]`
repos blocks on stdin — non-interactively it dies under the ERR trap with
"aborted at line 304". Sourcing the library removes the drift source and fixes
the prompt in the same move.

## Current state

- `bin/install-omarchy-quattro.sh:68-111` — the wrapper's header comment about
  the contract plus `run`, `run_root`, `write_root_file`, `append_root_file`
  (byte-identical to `bin/lib/common.sh:16-60` per `diff`; re-verify with
  `diff <(sed -n '75,111p' bin/install-omarchy-quattro.sh) <(sed -n '16,60p' bin/lib/common.sh)`
  — adjust ranges to what you find).
- `bin/lib/common.sh` also provides `write_user_file`, `have`, `info`, `warn`,
  `die`, `require_not_root`, `require_cmds`, `confirm`, `start_logging`, and a
  re-source guard (`OMACACHY_COMMON_SH`). Its header says "Sourced, never
  executed".
- The non-CachyOS prompt:
  ```bash
  if ! $IS_CACHYOS && ! $VERIFY_ONLY; then
      echo "Warning: this does not look like a CachyOS system …"
      if ! $ASSUME_YES; then
          read -r -p "Continue anyway? [y/N] " reply
          [[ $reply =~ ^[Yy]$ ]] || { echo "Aborting."; exit 1; }
      fi
  fi
  ```
- The main prompt (search `Proceed?`):
  ```bash
  read -r -p "Proceed? [y/N] " reply
  ```
  inside a `if ! $ASSUME_YES && ! $DRY_RUN; then` guard.
- `bin/lib/common.sh`'s `confirm` is documented as: "true unless the user
  declines. Auto-true when ASSUME_YES or DRY_RUN is set, so a plan can always
  be printed unattended."
- The wrapper is the only script in the repo that does not source the library;
  `bin/nvidia.sh:17`, `bin/amd-rocm.sh:11`, `bin/omacachy-profile-*.sh` and
  `bin/omacachy-doctor.sh` all do.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `bash -n bin/*.sh bin/lib/*.sh tests/run.sh && shellcheck --severity=warning -x bin/*.sh bin/lib/*.sh tests/run.sh` | exit 0 |
| Fixture suite | `tests/run.sh` | `0 failed` |
| Output equivalence | the normalized diff in Step 5 | empty |

## Scope

**In scope**: `bin/install-omarchy-quattro.sh` only.
**Out of scope**: `bin/lib/common.sh` (do not change its behaviour — no new
helpers, no prompt-text edits), the wrapper's own `host_path`/`decide`/`step`
helpers (keep them; they are the sysroot seam).

## Git workflow

- Branch: `advisor/032-wrapper-common-sh-dedupe`
- Commit message, e.g.: `Source the shared dry-run contract from the wrapper; use confirm for its prompts`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Capture the baseline output

```bash
cd /home/t1nk33r/Projects/omacachy/omacachy
OMACACHY_LOG=/tmp/omacachy-fixed.log bin/install-omarchy-quattro.sh --dry-run --yes >/tmp/dryrun-pre.txt 2>&1; echo "rc=$?"
sed -E 's/20[0-9]{6,12}/TS/g' /tmp/dryrun-pre.txt >/tmp/dryrun-pre.norm
```

**Verify**: `rc=0` and the file has the plan output (the dev host's
"does not look like a CachyOS system" warning is expected).

### Step 2: Check for name collisions

```bash
comm -12 \
  <(sed -n 's/^\([A-Za-z_][A-Za-z_0-9]*\)() {.*/\1/p' bin/install-omarchy-quattro.sh | sort -u) \
  <(sed -n 's/^\([A-Za-z_][A-Za-z_0-9]*\)() {.*/\1/p' bin/lib/common.sh | sort -u)
```

Expected: exactly `append_root_file`, `run`, `run_root`, `write_root_file`.
If anything else appears (e.g. `warn` or `die` already defined in the
wrapper), STOP — sourcing would silently change behaviour.

**Verify**: as above.

### Step 3: Replace the copies with the source

- Delete the four helper bodies and their comment block at `:68-111`.
- Put in their place:
  ```bash
  # run / run_root / write_root_file / append_root_file and the dry-run
  # contract they implement live in bin/lib/common.sh, shared with the
  # profile migration scripts.
  # shellcheck source=bin/lib/common.sh
  source "$SCRIPT_DIR/lib/common.sh"
  ```
- Place it exactly where the definitions were (after `SCRIPT_DIR` exists and
  before first use). The library's `DRY_RUN=${DRY_RUN:-false}` default is
  harmless: the wrapper reassigns the flag after parsing.

**Verify**: `bash -n bin/install-omarchy-quattro.sh` → exit 0;
`grep -n 'lib/common.sh' bin/install-omarchy-quattro.sh` → one source line;
`sed -n '/^run() {/,/^}/p' bin/install-omarchy-quattro.sh` → empty.

### Step 4: Use `confirm` for both prompts

- Non-CachyOS prompt → `confirm "Continue anyway?" || { echo "Aborting."; exit 1; }`.
- `Proceed?` prompt → `confirm "Proceed?" || { echo "Aborting."; exit 1; }`
  (the guard around it can go: `confirm` already auto-answers for
  `--yes`/`--dry-run`).

The prompt wording is a user-visible surface; the shared helper's prompt
format may differ slightly from `[y/N]`. That is accepted; note the difference
in your report so the reviewer sees it.

**Verify**: `grep -n 'read -r -p' bin/install-omarchy-quattro.sh` → no matches;
`grep -n 'confirm ' bin/install-omarchy-quattro.sh` → two call sites.

### Step 5: Prove nothing else changed

```bash
OMACACHY_LOG=/tmp/omacachy-fixed.log bin/install-omarchy-quattro.sh --dry-run --yes >/tmp/dryrun-post.txt 2>&1; echo "rc=$?"
sed -E 's/20[0-9]{6,12}/TS/g' /tmp/dryrun-post.txt >/tmp/dryrun-post.norm
diff /tmp/dryrun-pre.norm /tmp/dryrun-post.norm && echo "identical"
```

Expected: `identical` (the run's timestamp and the log path are the only
expected differences, both normalized/pinned).

**Verify**: as above; also `tests/run.sh` → `0 failed` (the fixtures assert the
`DRYRUN:` text these helpers print, so they are the second net).

## Test plan

- Step 5's diff plus the fixture matrix are the regression net.
- If plan 029 has landed, its `units`/`picker`/`gpu` sections keep passing;
  add nothing new here.
- The dry-run prompt fix is not directly testable (it needs a non-CachyOS
  host), but Step 5's run *is* a non-CachyOS host with `--yes`; add to your
  report the output of a `--dry-run` **without** `--yes` to show it no longer
  blocks:
  `timeout 20 bin/install-omarchy-quattro.sh --dry-run </dev/null | head -3`
  → exits 0, prints the plan (previously: ERR-trap abort).

## Done criteria

- [ ] The wrapper sources `bin/lib/common.sh` and defines none of the four helpers
- [ ] No `read -r -p` remains; both prompts go through `confirm`
- [ ] `--dry-run` without `--yes` completes without blocking (report command)
- [ ] Normalized dry-run diff is empty; fixture suite `0 failed`
- [ ] Lint gate exit 0
- [ ] No files outside `bin/install-omarchy-quattro.sh` are modified
- [ ] `plans/README.md` status row updated

## STOP conditions

- Step 2 shows any additional name collision.
- The fixture suite fails after Step 3 for a reason other than prompt text —
  STOP and report the failing assertions.
- `confirm`'s semantics differ from the wrapper's on a TTY in a way that
  changes abort behaviour for a real install (review the helper body before
  landing; it is short).

## Maintenance notes

- The wrapper's `host_path`/`decide`/`step`/`build`-level helpers stay local —
  they are the sysroot seam and the profile scripts do not need them.
- Reviewer: this is the riskiest wrapper change in the batch; read the whole
  diff against the fixture output, not just the source.
