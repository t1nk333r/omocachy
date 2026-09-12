# Plan 045: Take a snapper rollback point before the first change

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW (non-fatal by construction)
- **Depends on**: 027 (snapper assertion), 040 (snapper re-apply pre-empt)
- **Category**: feature
- **Planned at**: commit `d3d8a82`, 2026-09-12
- **Executed**: 2026-09-12, in the same commit as this file.

## Why this matters

The wrapper's first run on a machine touches more than the apply stages do:
`/etc/pacman.conf` (the `[omarchy]` repo and the `HookDir` lines), the pacman
keyring, the boot-hook directory, `/etc/cachyos-preserved`, the mkinitcpio
`HOOKS` drop-in, `/etc/os-release` and `/etc/nsswitch.conf`, the sddm drop-ins
and the user's `$HOME`. All of that happens before `omarchy-apply-system` runs.
On a btrfs root the cheapest undo is a snapshot, and the moment to take it is
*before* the first write — which is what the user asked for ("on first fire of
script take a snapper snapshot").

## What changed

- `bin/install-omarchy-quattro.sh`: new step **"Rollback point (snapper)"**
  immediately before the first mutating step (`step "Repo + keyring"`). On a
  first run, when `/etc/snapper/configs/root` exists, it runs
  `snapper --no-dbus -c root create --description "before omacachy install"
  --cleanup-algorithm number --userdata important=yes --print-number` and prints
  the number. `--no-dbus` matches the pre-empt step's discipline (no session
  bus on a fresh machine), and `important=yes` keeps number/timeline cleanup
  from deleting the rollback point.
  - **Only on a first run**: a re-apply already has one, and re-snapshotting
    consumes space for nothing.
  - **Only when snapper is configured for `/`**: `snapper create` needs the
    config, and CachyOS pre-creates `/.snapshots`, so `create-config` cannot be
    used as a fallback. Absent config → a printed skip, not a failure.
  - **Never fatal**: a failure warns, explains that there is then no rollback
    point, and continues.
  - Dry run prints the exact command. Decision: `snapper_snapshot` =
    `created:<n> | would-create | skipped-reapply | skipped-no-config | failed`.
- Fixtures: `cachyos-hookdir-preset` gains a configured snapper root (so the
  dry run takes the `would-create` branch) and asserts
  `snapper_snapshot=would-create`; `cachyos-limine-luks` asserts
  `snapper_snapshot=skipped-no-config`.

## Verification

- `tests/run.sh` → `307 passed, 0 failed`; lint gate exit 0; the fixture matrix
  pins both new branches.
- Dry run against the configured fixture prints
  `DRYRUN: sudo snapper --no-dbus -c root create …` and records
  `snapper_snapshot=would-create`.
- Lab (private copy, pristine guest with snapper configured): the first run
  takes a real numbered snapshot (`snapper -c root list`) and stays at
  `wrapper-exit=0` / 19 PASS; a second run skips it
  (`Re-apply: no pre-install snapshot`) and creates no second snapshot.

## Considered and rejected

- **Snapshot on every run**: the user asked for the first fire, and repeated
  snapshots on re-applies cost space for a state that is already covered.
- **`snapper create-config` fallback when no config exists**: fails on CachyOS
  because `/.snapshots` already exists (the same failure plan 040's pre-empt
  works around); a skip with a clear message is honest, and the pre-empt still
  leaves the system with a template config afterwards.
- **Making it fatal**: a snapshot is a safety net, not a prerequisite; aborting
  an otherwise-fine install because snapper misbehaved would be worse than
  proceeding without it.
- **`pre`/`post` snapshot pairs**: those model a transaction with a matching
  post snapshot; a manual rollback point is a plain `single` snapshot with
  `important=yes`.
