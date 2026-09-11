# Plan 031: Keep `/etc/pacman.d/hooks/` listed in every `ensure_hookdir_lines` branch

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If any
> STOP condition occurs, stop and report — do not improvise. When done, update
> the status row for this plan in `plans/README.md` (or leave it to the
> reviewer).
>
> **Drift check (run first)**: `git diff --stat e80b564..HEAD -- bin/install-omarchy-quattro.sh tests/fixtures/`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (same file as plans 021, 027, 028, 032 — execute serially with them)
- **Category**: bug
- **Planned at**: commit `e80b564`, 2026-09-11
- **Executed**: 2026-09-11 (landed at `5464d18`); the insertion order is stock-before-ours even when the ours-line already exists (later HookDirs win), and Step 2 was implemented after review as a check that runs before the Limine early-return when pacman.conf declares any HookDir.

## Why this matters

The wrapper's own comment states the invariant: "Specifying [HookDir] at all
replaces the /etc/pacman.d/hooks default, so both lines are written, in order."
The os-release preserve hook lives in `/etc/pacman.d/hooks/`
(`:1110`, `:1121-1122`), so if that directory ever falls out of the search
path, the hook silently stops firing and `/etc/os-release` reverts to
`ID=omarchy` on the next `omarchy-settings` upgrade. Two of the three branches
in `ensure_hookdir_lines` break the invariant: the "already registered" branch
returns without checking the stock line, and the "file already sets HookDir"
branch inserts only the wrapper's own line.

## Current state

- `bin/install-omarchy-quattro.sh:938-975` — `ensure_hookdir_lines`:
  - branch 1 (`:941-945`): `if grep -qxF "HookDir = $OMACACHY_HOOK_DIR/" "$conf"; then echo "…already registered…"; return 0; fi`
  - branch 2 (`:946-962`): `elif grep -qE '^\s*HookDir\s*=' "$conf"` → awk-inserts **only**
    `HookDir = $OMACACHY_HOOK_DIR/` after the last existing HookDir line.
  - branch 3 (`:963-967`): no HookDir at all →
    `run_root sed -i "/^\[options\]/a HookDir = $PACMAN_HOOK_DIR/\nHookDir = $OMACACHY_HOOK_DIR/" /etc/pacman.conf`
    (both lines, "in this order").
  - post-write guard (`:969-972`) verifies only the wrapper's own line.
- The constants used: `$PACMAN_HOOK_DIR` (`/etc/pacman.d/hooks/`) and
  `$OMACACHY_HOOK_DIR` (`/etc/pacman.d/hooks-omacachy/`, `:500`).
- `check_hookdir_override` (`:692-694`) returns 0 for non-Limine… check the
  live code: it currently returns 0 for Limine machines and otherwise verifies
  the override somewhere — read it before editing and keep its shape.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `bash -n bin/*.sh bin/lib/*.sh tests/run.sh && shellcheck --severity=warning -x bin/*.sh bin/lib/*.sh tests/run.sh` | exit 0 |
| Fixture suite | `tests/run.sh` | `0 failed` (new fixture included) |
| New fixture alone | `tests/run.sh matrix` | `0 failed` |

## Scope

**In scope**: `bin/install-omarchy-quattro.sh` (`ensure_hookdir_lines` +
`check_hookdir_override`), one new fixture directory.

**Out of scope**: the inert-hook writing, the `[options]` anchor logic for the
no-HookDir case (branch 3 is already correct), plan 016's design.

## Git workflow

- Branch: `advisor/031-hookdir-both-lines`
- Commit message, e.g.: `Ensure /etc/pacman.d/hooks stays listed in every HookDir branch`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Restructure to "ensure both lines"

Replace branches 1 and 2 with a single missing-lines path:

```bash
ensure_hookdir_lines() {
    local conf tmp
    conf="$(host_path /etc/pacman.conf)"
    local have_stock=false have_ours=false
    grep -qxF "HookDir = $PACMAN_HOOK_DIR/" "$conf" 2>/dev/null && have_stock=true
    grep -qxF "HookDir = $OMACACHY_HOOK_DIR/" "$conf" 2>/dev/null && have_ours=true
    if $have_stock && $have_ours; then
        echo "HookDir lines already registered in /etc/pacman.conf."
        return 0
    fi
    local -a missing=()
    $have_stock || missing+=("HookDir = $PACMAN_HOOK_DIR/")
    $have_ours  || missing+=("HookDir = $OMACACHY_HOOK_DIR/")
    printf 'Adding to /etc/pacman.conf: %s\n' "${missing[*]}"
    ...insert `missing` after the last existing HookDir line, or after [options] when none exists...
}
```

- Insertion: reuse the existing awk machinery from branch 2, extended to print
  every element of `missing` in order after the last HookDir line; when the
  file has no HookDir line, keep branch 3's `sed`/`awk` behaviour but drive it
  from `missing` too (so a future third line needs no new branch).
- Dry-run: keep printing the lines being added (the `printf` above runs in
  both modes) plus the existing `DRYRUN: rewrite …` line.
- Post-write guard: verify **both** lines
  (`grep -qxF` for each) before returning success; keep the existing error
  message but name the missing line.

**Verify**: `bash -n bin/install-omarchy-quattro.sh` → exit 0;
`sed -n '/ensure_hookdir_lines/,/^}/p' bin/install-omarchy-quattro.sh` shows
one insertion path and the two-line guard.

### Step 2: Scope the assertion to the real invariant

In `check_hookdir_override`, keep its Limine early-return, then: if
pacman.conf contains any `HookDir` line, require
`HookDir = $PACMAN_HOOK_DIR/` to be present. (On machines where the wrapper
never wrote a HookDir line, nothing changes.) Read the live function first and
preserve its existing checks.

**Verify**: `grep -n 'PACMAN_HOOK_DIR' bin/install-omarchy-quattro.sh` → the
constant is used in `ensure_hookdir_lines` and in `check_hookdir_override`.

### Step 3: New fixture `cachyos-hookdir-preset`

```bash
cp -a tests/fixtures/cachyos-grub-plain tests/fixtures/cachyos-hookdir-preset
printf 'HookDir = /usr/local/lib/hooks/\n' >>tests/fixtures/cachyos-hookdir-preset/etc/pacman.conf
printf 'HookDir = /etc/pacman.d/hooks/\nHookDir = /etc/pacman.d/hooks-omacachy/\n' >>tests/fixtures/cachyos-hookdir-preset/expected.stderr
```

(The `expected.stderr` needles are contains-only assertions against the
captured output — see `tests/run.sh:169-175` — so the two added lines pin
"both lines are ensured". Keep the copied fixture's existing needles.)

**Verify**: `tests/run.sh matrix` → `0 failed`, including the new fixture's
checks; the fixture's output mentions both HookDir lines.

### Step 4: Suite

**Verify**: `tests/run.sh` → `0 failed`; lint gate → exit 0.

## Test plan

- The new fixture is the regression: against the current code, branch 2 prints
  only the omacachy line, so the stock-line needle fails; after Step 1 both
  needles pass.
- The branch-1 case (own line present, stock line absent) is not covered by a
  fixture — add a second fixture only if it is cheap (copy the new one and
  pre-add the omacachy line to its pacman.conf); otherwise note the gap in
  your report.

## Done criteria

- [ ] Every branch ensures both `HookDir` lines; the post-write guard checks both
- [ ] `check_hookdir_override` flags a declared-HookDir file that omits the stock dir
- [ ] New fixture passes and the eight other fixtures are unchanged
- [ ] Lint gate exit 0; `tests/run.sh` `0 failed`
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- `pacman.conf(5)` semantics turn out to be additive rather than replacing
  (then the *assertion* half is wrong even though the both-lines write is
  harmless) — STOP and report rather than encoding the assumption further; the
  wrapper's comment and plan 016 both claim replacement, and this plan follows
  them.
- Branch 3's `[options]` anchor behaves differently than the excerpt when
  driven from `missing` — keep the original sed form and report.

## Maintenance notes

- If a future HookDir line is added, extend the `missing` list — no new branch.
- Reviewer: this widens the search path only (`HookDir` entries are additive
  in effect even under the replacement reading); confirm the dry-run prints
  exactly the lines a real run would write.
