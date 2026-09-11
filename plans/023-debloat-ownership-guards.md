# Plan 023: Teach the debloat picker upstream's ownership guards for cursor-agent, muse and hermes

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If any
> STOP condition occurs, stop and report — do not improvise. When done, update
> the status row for this plan in `plans/README.md` (or leave it to the
> reviewer).
>
> **Drift check (run first)**: `git diff --stat e80b564..HEAD -- bin/debloat-quattro.sh`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `e80b564`, 2026-09-11

## Why this matters

`bin/debloat-quattro.sh` offers the user every `rm -f ~/.local/bin/…` name it
can parse out of Omarchy's `omarchy-remove-preinstalls` — including three names
upstream removes **only when it owns them**. On this host `--list` offers
`cursor-agent`, `muse` and `hermes`. On a machine where those paths hold a
user's own launcher (Cursor's installer-created script, a personal Muse
wrapper, Hermes Desktop's own command), ticking the entry `rm -f`s a
user-owned file with no backup. The README sells the picker as "delegated to
Omarchy's own tools … so behavior tracks upstream"; upstream's guards are part
of that behaviour.

## Current state

- `bin/debloat-quattro.sh:122-140` — `parse_stub_list` captures every
  `rm -f ~/.local/bin/…` line in the installed upstream script:
  ```awk
  /^[[:space:]]*rm -f ~\/\.local\/bin\// { capture=1 }
  ```
  (It re-triggers on each block, including the ones inside `if` bodies.)
- `:185-190` — offering:
  ```bash
  for stub in "${parsed_stubs[@]}"; do
      if [[ -e "$BIN_DIR/$stub" ]]; then
          stub_present+=("$stub")
  ```
- `:437-445` — removal:
  ```bash
  rm -f "$BIN_DIR/$stub"
  ```
- Upstream's guards, quoted from `/usr/share/omarchy/bin/omarchy-remove-preinstalls`
  (2026-09-11, omarchy 4.0.3):
  ```bash
  # Cursor's own installer links ~/.local/bin/cursor-agent as well, so only
  # the mise wrapper omarchy-mise-install wrote is a preinstall.
  if [[ -f ~/.local/bin/cursor-agent && ! -L ~/.local/bin/cursor-agent ]] &&
      grep -Eq '^mise use -g .*"cursor-agent"' ~/.local/bin/cursor-agent; then
      rm -f ~/.local/bin/cursor-agent
  # Preserve a user-managed Muse launcher at the same path.
  if [[ -f ~/.local/bin/muse && ! -L ~/.local/bin/muse ]] &&
      grep -Eq '^mise use -g .*"http:muse\[' ~/.local/bin/muse; then
      rm -f ~/.local/bin/muse
  # hermes: decided by `omarchy-install-hermes-cli --owns`
  ```
  The first block (`codex claude gemini …` backslash-continued) is
  unconditional and stays as it is.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| List candidates (read-only) | `bin/debloat-quattro.sh --list` | prints categories; `cursor-agent` absent unless owned |
| Lint | `bash -n bin/*.sh bin/lib/*.sh tests/run.sh && shellcheck --severity=warning -x bin/*.sh bin/lib/*.sh tests/run.sh` | exit 0 |
| Fixture suite | `tests/run.sh` | `0 failed` |

## Scope

**In scope**: `bin/debloat-quattro.sh`, plus one regression case in `tests/run.sh`.
**Out of scope**: the package list, web apps, TUIs, bindings rewrite — unchanged.

## Git workflow

- Branch: `advisor/023-debloat-ownership-guards`
- Commit message, e.g.: `Mirror upstream's ownership guards in the debloat picker`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the ownership test

Next to `parse_stub_list`, add:

```bash
# True when this name is one the picker may remove: names upstream removes
# unconditionally always pass; the three guarded names pass only when the
# file is the immutable-mode wrapper Omarchy's own installer wrote.
stub_owned_by_omarchy() {
    local name="$1" file="$BIN_DIR/$name"
    case "$name" in
    cursor-agent)
        [[ -f $file && ! -L $file ]] && grep -Eq '^mise use -g .*"cursor-agent"' "$file"
        ;;
    muse)
        [[ -f $file && ! -L $file ]] && grep -Eq '^mise use -g .*"http:muse\[' "$file"
        ;;
    hermes)
        command -v omarchy-install-hermes-cli &>/dev/null && omarchy-install-hermes-cli --owns "$file"
        ;;
    *)
        return 0
        ;;
    esac
}
```

Adjust the `--owns` call to the exact interface you observe in
`omarchy-install-hermes-cli --help` (the guard's contract is what matters; if
`--owns` takes no argument, pass none).

**Verify**: `grep -n 'stub_owned_by_omarchy' bin/debloat-quattro.sh` → definition.

### Step 2: Gate offering and removal

- In the enumeration (`:185-190`), change the gate to:
  ```bash
  if [[ -e "$BIN_DIR/$stub" ]] && stub_owned_by_omarchy "$stub"; then
  ```
- In the removal loop (`:437-445`), add the same guard before `rm -f`; if it
  fails, print `skipping <name>: not the wrapper Omarchy installed` and continue.

**Verify**: `bash -n bin/debloat-quattro.sh` → exit 0; then a synthetic run:

```bash
d=$(mktemp -d); dd=$(mktemp -d); s=$(mktemp)
printf '#!/bin/sh\necho stub\n' >"$s"                      # fake upstream list with all three names
printf 'rm -f ~/.local/bin/codex \\\n  ~/.local/bin/cursor-agent\n  rm -f ~/.local/bin/cursor-agent\n  rm -f ~/.local/bin/muse\n  rm -f ~/.local/bin/hermes\n' >"$s"
printf '#!/bin/sh\nexit 0\n' >"$dd/codex"; chmod +x "$dd/codex"        # unconditional name exists
ln -sf /bin/true "$dd/cursor-agent"                                     # symlink → must NOT be offered
printf 'body\n' >"$dd/muse"                                             # no mise marker → must NOT be offered
DQ_APP_DIR=$d DQ_BIN_DIR=$dd DQ_OMARCHY_SCRIPT=$s bin/debloat-quattro.sh --list
```

Expected output: `codex` listed; `cursor-agent` and `muse` absent. Then create
`$dd/cursor-agent` as a regular file containing
`mise use -g "cursor-agent"@latest` and re-run → `cursor-agent` appears.

**Verify**: the two `--list` outputs above match those expectations.

### Step 3: Regression case in `tests/run.sh`

Add the Step 2 scenario as a case (use `$WORK` for the temp dirs, and the
harness's `ok`/`bad` helpers). Keep it to one case with three assertions:
symlink excluded, marker-less file excluded, marker file included.

**Verify**: `tests/run.sh` → `0 failed`, including the new case.

### Step 4: Host check

**Verify**: `bin/debloat-quattro.sh --list` on the dev host → `cursor-agent`,
`muse`, `hermes` no longer offered (unless this machine genuinely has the mise
wrappers); every other name that was listed before still is.

## Test plan

- The Step 3 case is the regression net; it must fail against the current code
  (which offers the symlink) and pass after Step 2.
- The upstream guard text is quoted above; if upstream changes it, re-derive
  from `/usr/share/omarchy/bin/omarchy-remove-preinstalls` rather than guessing.

## Done criteria

- [ ] `--list` no longer offers a symlinked `cursor-agent`/`muse` or a
      marker-less file — demonstrated by the new test case
- [ ] An owned `cursor-agent` (regular file, `mise use -g` marker) is still
      offered and removable
- [ ] Unconditional names (codex, claude, …) unchanged
- [ ] Lint gate exit 0; `tests/run.sh` `0 failed`
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- `omarchy-install-hermes-cli` is absent on the machine you test on and its
  `--owns` interface cannot be confirmed from `--help` or its source — STOP and
  report rather than guessing the guard.
- The upstream script's structure differs from the excerpt (upstream moved on).
- The code no longer matches the excerpts (drift).

## Maintenance notes

- Upstream may add guards for more names; the `case` is the place to extend.
  A cheap follow-up (not this plan) is to parse the guards instead of copying
  them — rejected for now because parsing shell conditions is fragile.
- Reviewer: confirm the removal loop still prints *something* for skipped
  names, so a user who expected the entry learns why it is gone.
