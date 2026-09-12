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
    config, and `create-config` can only make one while `/.snapshots` does not
    exist yet — true on a fresh CachyOS, false once snapper has ever been
    configured (that step creates the subvolume). Absent config → a printed
    skip, not a failure.
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
- Lab (private copy `t1nk33r-lab-snap`, pristine golden, snapper configured with
  `snapper --no-dbus -c root create-config /` there — the golden has no
  `/.snapshots` yet, so that succeeds):
  - first run printed `Took snapper snapshot 1 of / (important=yes,
    cleanup=number) as the pre-install rollback point.`, `snapper -c root list`
    then showed `1 | Sat Sep 12 16:48:35 2026 | before omacachy install |
    important=yes`, its `info.xml` carried `<cleanup>number</cleanup>` and
    `<key>important</key><value>yes</value>`, and the run stayed at
    `wrapper-exit=0` / 19 PASS with the snapper-config assertion still passing;
  - a second run printed `Re-apply: no pre-install snapshot (the first run took
    one).` and the snapshot list was unchanged (no second snapshot);
  - reproduced on a second fresh golden: identical step output and a snapshot
    with the same description/userdata.
  - The step's own note that "CachyOS pre-creates `/.snapshots`" was wrong and
    is corrected above: the subvolume appears when snapper is first configured,
    not from the installer.

## Considered and rejected

- **Snapshot on every run**: the user asked for the first fire, and repeated
  snapshots on re-applies cost space for a state that is already covered.
- **`create-config` fallback when no config exists**: on a true first run
  `/.snapshots` usually does not exist yet, so the wrapper *could* configure
  snapper on the fly — rejected anyway, because silently choosing a retention
  policy for someone's root filesystem is a system decision that belongs to the
  installer or the user. Plan 040's pre-empt still leaves a template config
  whenever the snapper stage needs one.
- **Making it fatal**: a snapshot is a safety net, not a prerequisite; aborting
  an otherwise-fine install because snapper misbehaved would be worse than
  proceeding without it.
- **`pre`/`post` snapshot pairs**: those model a transaction with a matching
  post snapshot; a manual rollback point is a plain `single` snapshot with
  `important=yes`.
