# Plan 029: Give the untested scripts a regression baseline

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If any
> STOP condition occurs, stop and report — do not improvise. When done, update
> the status row for this plan in `plans/README.md` (or leave it to the
> reviewer).
>
> **Drift check (run first)**: `git diff --stat e80b564..HEAD -- tests/run.sh bin/install-omarchy-quattro.sh bin/lib/profile.sh`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none, but it is *most valuable after* plans 020, 022, 023, 024, 025, 026 (their behaviour is what these cases pin)
- **Category**: tests
- **Planned at**: commit `e80b564`, 2026-09-11

## Why this matters

`tests/run.sh` executes exactly one of the nine `bin/` scripts (the wrapper)
plus `bin/lib/hooks-merge.sh`; 2,286 of the 4,143 lines under `bin/` are never
run by any test — the profile export/import/doctor trio (the newest and most
dangerous work line), the debloat picker, and the GPU scripts. The suite also
cannot exercise the wrapper's own assertion suite (it short-circuits under
`--dry-run`, and the checks read live paths), and the GPU probe bypasses the
`OMACACHY_SYSROOT` seam. This plan adds the harness sections and the cheap
coverage the code already enables, and routes the GPU probe through the seam.

## Current state

- `tests/run.sh` — one runner, sections `lint`, `hooks`, `matrix`, `purity`
  (`case "${1:-all}" in` at `:250`), helpers `ok`/`bad`/`head_`/`expect_eq`/
  `expect_contains` at `:26-37`, `$WORK` from `mktemp -d` + EXIT trap at
  `:21-22`. Fixtures are driven by `dry_run_fixture()` (`:143-152`) which sets
  `OMACACHY_SYSROOT`, `OMACACHY_DECISIONS_FILE`, `OMACACHY_LOG`.
- `bin/lib/profile.sh` exposes pure, fixture-friendly helpers:
  `profile_read_paths` (`:133-152`, refuses `PROFILE_SECRET_DIRS`), 
  `profile_pkg_denied` (`:118-131`), `profile_shelljson_plugin_ids`
  (`:189-200`), plus the lists `PROFILE_SECRET_DIRS`/`PROFILE_SECRET_FILE_GLOBS`/
  `PROFILE_PKG_DENY`.
- `bin/debloat-quattro.sh:15-19` documents the test-only overrides
  (`DQ_APP_DIR`, `DQ_BIN_DIR`, `DQ_OMARCHY_SCRIPT`, `DQ_BINDINGS_FILE`) and
  relaxes its Omarchy-4 guard for `--list`/`--dry-run` when one is set
  (`:66-82`).
- `bin/install-omarchy-quattro.sh:463`:
  ```bash
  GPU_TYPE="$(bash "$SCRIPT_DIR/gpu-detect.sh")"
  ```
  runs unconditionally, also under `OMACACHY_SYSROOT`; the seam contract
  (`:56-60`) says every read of host state goes through `host_path`.
- `bin/gpu-setup.sh:11-24` dispatches on `$GPU_TYPE` with branches
  `nvidia|amd|none` and no `default`.
- `tests/run.sh:13` still prints the stale claim "Nothing in this repo has ever
  been run on real CachyOS" — plan 030 fixes it; do not edit it here.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Everything | `tests/run.sh` | `N passed, 0 failed` (N grows) |
| New sections | `tests/run.sh units` / `tests/run.sh picker` / `tests/run.sh gpu` | each ends `0 failed` |
| Lint | `bash -n bin/*.sh bin/lib/*.sh tests/run.sh && shellcheck --severity=warning -x bin/*.sh bin/lib/*.sh tests/run.sh` | exit 0 |

## Scope

**In scope**: `tests/run.sh` (new sections + wiring into `all`), and the
three-line GPU-probe seam fix in `bin/install-omarchy-quattro.sh`.

**Out of scope**: routing the wrapper's `check_*` functions through the seam
and making the assertion suite sysroot-runnable (18 functions, needs its own
design — see Maintenance notes); any change to the scripts under test beyond
the GPU probe guard.

## Git workflow

- Branch: `advisor/029-regression-baseline`
- Commit message, e.g.: `Add unit, picker and GPU sections to the test runner; seam the GPU probe`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: `units` section — the pure helpers

Add `run_units()` with cases that source the library and assert directly:

```bash
# via: ( source "$REPO_DIR/bin/lib/profile.sh"; ... )
```

Cases (one `ok` each):
1. `profile_read_paths` on a temp paths file containing `.ssh` and
   `.config/hypr` prints only `.config/hypr` and mentions the refusal on stderr.
2. `profile_pkg_denied` denies `mesa-git` (adjust to the current policy: after
   plan 024 it must deny; before it, use `nvidia-utils` so the case is stable
   either way — pin what the plan's regression needs and note it in a comment).
3. `profile_pkg_denied` allows `firefox`.
4. `profile_shelljson_plugin_ids` on a temp `shell.json` containing
   `{"plugins":[{"id":"foo.bar"},{"id":"omarchy.builtin"}]}` prints `foo.bar`
   only.

**Verify**: `tests/run.sh units` → `0 failed` (4 new ok lines).

### Step 2: `picker` section — debloat enumeration

Using `$WORK` subdirs and the `DQ_*` overrides, run
`bin/debloat-quattro.sh --list` against a synthetic upstream script and assert:

1. a webapp `.desktop` in `DQ_APP_DIR` (with `Exec=omarchy-launch-webapp`) is
   listed; a TUI one (`Exec=xdg-terminal-exec --app-id=TUI.`) is listed under
   TUIs;
2. an installed package name appears under Packages when `pacman -Qq` can see
   it (use a package certain to be installed, e.g. `bash`, if you can put it
   in the synthetic list);
3. an `~/.local/bin` stub present in `DQ_BIN_DIR` is listed.

Keep the synthetic upstream script minimal, e.g.:

```bash
printf '%s\n' 'omarchy-pkg-drop bash neovim' 'rm -f ~/.local/bin/codex' >"$s"
```

**Verify**: `tests/run.sh picker` → `0 failed`.

### Step 3: `gpu` section — dispatch and the no-GPU path

```bash
shim="$WORK/shim"; mkdir -p "$shim"
printf '#!/bin/sh\nexit 0\n' >"$shim/lspci"; chmod +x "$shim/lspci"
PATH="$shim:$PATH" bash "$REPO_DIR/bin/gpu-setup.sh" --dry-run
```

Assert: output contains `No GPU detected` and exit status 0. (This pins the
`none` branch and proves the script is runnable under a stub, which the
current code is not — `gpu-detect.sh` runs `lspci` unguarded; if it exits
non-zero under the empty stub, that is a bug this case catches: check
`bin/gpu-detect.sh` and, if the stub makes it fail, extend the shim to print
nothing and exit 0 for every invocation and report what you changed.)

**Verify**: `tests/run.sh gpu` → `0 failed`.

### Step 4: Wire the sections in and keep `all` green

Add `units)`, `picker)`, `gpu)` to the `case` and run them from `all` (after
`hooks`, before `matrix` is a good spot). Keep `lint`, `hooks`, `matrix`,
`purity` semantics untouched.

**Verify**: `tests/run.sh` → all sections run, `0 failed`; count grows by the
new cases.

### Step 5: Seam the GPU probe

In `bin/install-omarchy-quattro.sh:463`, guard the probe:

```bash
if [[ -n $SYSROOT ]]; then
    GPU_TYPE="none"
else
    GPU_TYPE="$(bash "$SCRIPT_DIR/gpu-detect.sh")"
fi
```

(Under a sysroot the fixtures have no GPU; the value only feeds the printed
summary today.) If the matrix's expectations include a GPU line, they will
still pass — verify with the suite. Add one assertion in the `gpu` section that
a fixture run prints `GPU vendor: none`… only if a fixture's output is
available to the section; otherwise note the seam gap in the plan report
instead of building cross-section coupling.

**Verify**: `tests/run.sh` → `0 failed` (matrix unchanged).

## Test plan

- The new sections *are* the tests; the regression value is that they run the
  scripts that had none.
- Each new case must be deterministic, offline, and `$WORK`-scoped (the
  harness's existing standard).

## Done criteria

- [ ] `tests/run.sh units`, `picker`, `gpu` each run and pass
- [ ] `tests/run.sh` runs them from `all`; `0 failed`
- [ ] The GPU probe is skipped under `OMACACHY_SYSROOT`
- [ ] Lint gate exit 0
- [ ] No files outside `tests/run.sh` and the wrapper probe guard are modified
- [ ] `plans/README.md` status row updated

## STOP conditions

- `bin/debloat-quattro.sh`'s guard refuses `--list` despite the overrides —
  STOP and report (that guard is part of what this plan's cases would pin).
- The synthetic `pacman -Qq` assumption fails (the case needs a package the
  host has; pick another and say which).
- Any change appears to require touching the scripts under test beyond the
  three-line probe guard.

## Maintenance notes

- Deferred, deliberately: making the wrapper's `check_*` assertion functions
  sysroot-runnable (route their reads through `host_path`, let the suite
  evaluate under a sysroot, add a broken-fixture case). It is the right
  follow-up but it changes the suite's execution semantics and deserves its own
  plan; `plans/027-snapper-assertion.md` and `plans/025-doctor-bundle-gate.md`
  currently pin their fixes by source shape for that reason.
- New behaviour fixes should now land with a case in one of these sections;
  reviewers should ask for it.
