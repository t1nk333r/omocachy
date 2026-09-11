# Plan 042: The closure must ship Omarchy's `mise-bin`, not `[extra]`'s `mise`

## Status

- **Priority**: P1
- **Effort**: XS
- **Risk**: LOW
- **Depends on**: 037 (which added `mise` to the closure)
- **Category**: bug
- **Planned at**: commit `541dec3`, 2026-09-11
- **Executed**: 2026-09-11, in the same commit as this file.

## Why this matters

Plan 037 added `mise` to `OMARCHY_ISO_CLOSURE` after a fresh guest's seeding
died on `mise: command not found`. On a machine that already has Omarchy — the
re-apply path, and any CachyOS box that has ever run this installer — that
closure entry is a **package conflict**:

```
:: mise-2026.9.1-1 and mise-bin-2026.9.4-1 are in conflict. Remove mise-bin? [y/N]
error: failed to prepare transaction (conflicting dependencies)
```

Measured on the Limine + LUKS2 guest: `[omarchy]` ships
`mise-bin 2026.9.4-1` with `Provides: mise`, `Conflicts With: mise`; `[extra]`
ships `mise 2026.9.1-1`. Omarchy's own installation pulls `mise-bin`, so the
closure asking for `mise` can only ever fight it — and the install aborts
before anything is installed, at the package step.

## What changed

- `bin/install-omarchy-quattro.sh`: `OMARCHY_ISO_CLOSURE` gains `mise-bin`
  instead of `mise`; the pre-apply gate reads `"cmd:mise=mise-bin"` (the
  command is still `mise` — both packages provide it).
- `tests/fixtures/cachyos-limine-luks/expected.decisions`: the `iso_closure`
  line updated.

## Verification

- `tests/run.sh` → `257 passed, 0 failed`; lint gate exit 0.
- Guest (Limine + LUKS2, Omarchy 4 installed, `mise-bin` present): the package
  step prepares the transaction instead of aborting on the conflict, and the
  run reaches the assertion suite.
- Guest (systemd-boot, minimal golden, no mise): `mise-bin` resolves from the
  `[omarchy]` repo the step before, and `cmd:mise` still gates it.

## Considered and rejected

- **Keep `mise` and add `--overwrite`/`--ask` to pacman**: weakens the
  installer's package handling for a conflict that only exists because the
  wrong package was named; `mise-bin` is what Omarchy installs anyway.
- **Drop the entry and let Omarchy's own dependency pull `mise-bin`**: that is
  what failed in plan 037 — on the minimal golden nothing pulls it before
  seeding runs, and the seeding script requires the binary to exist.
