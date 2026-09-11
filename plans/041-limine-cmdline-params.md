# Plan 041: Keep Omarchy's kernel arguments when /etc/default/limine assigns KERNEL_CMDLINE

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW–MEDIUM (edits a boot config, additively, with a backup)
- **Depends on**: 016/017 (the initramfs_async=0 finding), 029
- **Category**: bug
- **Planned at**: commit `547f15a`, 2026-09-11
- **Executed**: 2026-09-11, in the same commit as this file.

## Why this matters

Found by re-running the wrapper on the Limine + LUKS2 guest against current
HEAD (release gate 1's "the plan-017 fixes have not been re-run on a guest").
The install ended in **FAIL**: *"the generated Limine entries keep
omarchy-settings' initramfs_async=0 on a LUKS host (nothing replaced
KERNEL_CMDLINE with '=')"*.

The two sides of the machine disagree, and real CachyOS is always in this
state:

- Omarchy's drop-in appends its arguments —
  `/etc/limine-entry-tool.d/omarchy-defaults.conf:10:
  KERNEL_CMDLINE[default]+=" initramfs_async=0"`.
- CachyOS's installer writes the whole command line as an **assignment** —
  `/etc/default/limine:2: KERNEL_CMDLINE[default]="rd.luks.uuid=… root=UUID=…"`
  — and that file loads *after* the drop-ins, so the assignment replaces
  Omarchy's value.

Result on the guest: the regenerated `/boot/limine.conf` entries carry no
`initramfs_async=0`, i.e. the unthemed-text-LUKS-prompt regression plan 016
fixed is back, and the wrapper's own assertion (plan 029) fails the install
because of it.

The previous code detected this, printed a three-line warning, recorded
`limine_cmdline_style=assign-overrides-omarchy` — and deliberately did **not**
act ("rewriting someone's kernel command line is exactly the class of change
that does not get a second try"). With the assertion in place that combination
means: on real CachyOS the installer can never finish green, and the machine
keeps a defect the user is told about but not helped with.

## What changed

- `bin/install-omarchy-quattro.sh` (Limine defaults block): when
  `/etc/default/limine` assigns `KERNEL_CMDLINE[...]`, the parameters Omarchy's
  drop-ins append (`KERNEL_CMDLINE[...]+="…"`, read from
  `/etc/limine-entry-tool.d/*.conf`) are appended to every assignment that
  lacks them — `default`-keyed parameters to all assignments (that is their
  meaning: the baseline an assignment replaces), same-key ones to their own
  key. Nothing is removed or reordered, the original is kept as
  `$LIMINE_DEFAULT.$BACKUP_SUFFIX`, the DRY RUN prints what it would append,
  and a second run finds nothing missing. Decision:
  `limine_cmdline_style=assign-params-appended` when it acted,
  `assign-overrides-omarchy` only when no drop-in arguments exist to append.
- `tests/fixtures/cachyos-limine-luks`: now carries the real drop-in
  (`etc/limine-entry-tool.d/omarchy-defaults.conf`), expects
  `assign-params-appended`, and its `expected.stderr` pins both the warning and
  the planned append line.

## Verification

- `tests/run.sh` → `256 passed, 0 failed` (matrix 114); lint gate exit 0.
- The fixture's dry run prints the warning and
  `DRYRUN: append Omarchy's kernel arguments to the KERNEL_CMDLINE assignments
  in /etc/default/limine`, and decides `assign-params-appended`.
- Guest (Limine + LUKS2, Omarchy 4 installed, real CachyOS
  `/etc/default/limine`): the run regenerates the entries with the parameter
  present, and the assertion suite reports 19 PASS / 0 FAIL — the run that
  previously failed on this exact check.

## Considered and rejected

- **Warn and tolerate (leave the assertion failing)**: ships a known-broken
  LUKS prompt on every real CachyOS machine; the wrapper already knows the
  parameter is missing and already knows what it should be.
- **Rewrite the assignments to `+=`**: changes the meaning of the user's file
  for *other* drop-ins too, and a later CachyOS tool writing the file again
  would undo it; appending the parameters is the smaller, self-healing change.
- **Drop `initramfs_async=0` from the expected entries**: that parameter is
  the fix for the unthemed LUKS prompt (plan 016); removing the check would
  delete the evidence rather than the bug.
