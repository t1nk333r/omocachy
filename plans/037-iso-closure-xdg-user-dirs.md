# Plan 037: Ship `xdg-user-dirs` and `mise` in the ISO closure (user seeding needs both)

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `f1496e3`, 2026-09-11
- **Executed**: 2026-09-11, in the same commit as this file.

## Why this matters

Found by the release-gate-3 systemd-boot run — a **fresh** install on the
minimal CachyOS 260809 golden (the GRUB lab's, `~/Work/t1nk33r-lab-cachyos-*`).
The wrapper got through the package transaction, `omarchy-apply-system`, the
post-apply reconciliation, SDDM and the `/etc/skel` replay, then died twice in
**user-level config seeding**, one missing command at a time:

1. `/usr/bin/omarchy-provision-user: line 106: xdg-user-dirs-update: command
   not found` → `Error: aborted at line 43 (exit 127) during step: User-level
   config seeding`.
2. After that was installed: `/usr/share/omarchy/install/user/mise-work.sh:
   line 10: mise: command not found` → the same abort.

Neither command is shipped by Omarchy's own install lists (checked in the
guest: `grep -rn 'xdg-user-dirs\|mise' /usr/share/omarchy/install/` finds no
package list that provides them), and on an ISO install both arrive
transitively through the desktop package set. On the minimal/server-profile
CachyOS this project targets, they do not — so the install aborts *after*
everything expensive has succeeded. This is exactly the class plan 017's ISO
closure exists for (`cups`, `updatedb`, `ufw-docker`, …); the earlier
validation guests had these two by luck of their golden's package set.

## What changed

- `bin/install-omarchy-quattro.sh`:
  - `xdg-user-dirs` and `mise` appended to `OMARCHY_ISO_CLOSURE`, with both
    observations added to the closure's evidence comment.
  - `cmd:xdg-user-dirs-update=xdg-user-dirs` and `cmd:mise=mise` added to
    `APPLY_REQUIREMENTS`, so the pre-apply gate proves both exist before the
    run goes deep.
- `tests/fixtures/cachyos-limine-luks/expected.decisions`: the pinned
  `iso_closure=` string now ends `… plocate xdg-user-dirs mise`.

## Verification

- `tests/run.sh` → `250 passed, 0 failed`; lint gate exit 0.
- Re-run on the same systemd-boot guest completes the seeding step and reaches
  the assertion suite (lab log referenced by the gate-3 record).

## Considered and rejected

- **Only adding the packages, without the `APPLY_REQUIREMENTS` entries**: the
  gate is what turns "installed somewhere in a large transaction" into
  "present before we need it"; the lists are maintained together.
- **Guarding the seeding step instead (skip provisioning when a command is
  missing)**: wrong direction — both commands are genuinely needed for a
  correct Omarchy user; provisioning them is the fix.
- **Adding `node`/`npm` too**: `mise-work.sh`'s Node step already tolerates the
  missing ISO tarball in the `provision-owner` context (plan 017), and it
  installs Node through mise afterwards; only the `mise` binary itself was
  missing.
