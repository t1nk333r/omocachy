# Plan 040: Make the apply step's failures visible and its non-idempotent stages safe

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MEDIUM (moves files on `/boot`; backups taken)
- **Depends on**: 031 (boot-hook policy), 037/039 (closure)
- **Category**: bug
- **Planned at**: commit `fd64b93`, 2026-09-11
- **Executed**: 2026-09-11, in the same commit as this file.

## Why this matters

Three defects surfaced one after another on the systemd-boot CachyOS guest
during release gate 2. Each one aborts or fails a real install, and together
they made the failure *invisible*: the wrapper reported only
`Error: aborted at line 51 (exit 1) during step: Running omarchy-apply-system`
with no reason, because `omarchy-apply-system` re-points its own log at
`/var/log/omarchy-install.log`.

**1. Snapper re-apply is not idempotent on a machine where `/.snapshots`
exists but `/etc/snapper/configs/root` does not.** `install/config/snapper.sh:7`
runs `snapper -c root create-config /` only when that config file is absent, and
that call fails ("creating btrfs subvolume .snapshots failed since it already
exists") when the subvolume is already there — the CachyOS layout, and also the
state left when the config is moved aside or removed. `apply-system` aborts
with exit 1 and no console output. Measured on the guest: four applies at
20:04–20:11 completed (config present, `if` skipped), then two applies at
20:14/20:15 failed once the config was gone while `/.snapshots` (created
20:04:28) stayed.

**2. Stage failures inside apply-system are invisible.** Its log is a different
file, its abort carries only the stage's exit code, and the wrapper's
`diagnose_failure` scans only its own log — so the user gets "aborted at line
51" and nothing else.

**3. Limine artefacts stay on `/boot` on a machine Limine does not boot.**
Omarchy's snapper stage does `systemctl enable --now ... limine-snapper-sync
.service`; on a machine with CachyOS's Limine stack installed (the guest, and
the `cachyos-sdboot-luks` fixture) that service writes `/boot/limine.conf` and
a Limine UKI before the wrapper disables it. The wrapper's own assertion
("non-limine machine has no Limine config or UKI on /boot") therefore failed
with `Limine artefacts on a systemd-boot machine: /boot/EFI/Linux/omarchy_linux
-cachyos.efi /boot/limine.conf /boot/limine.conf.old`, and nothing in the run
told the user what to do about it. The same pair is written by
`limine-mkinitcpio-hook`'s PATH shim on every kernel transaction (the reason the
PATH pin of plan 031 exists).

## What changed

- `bin/install-omarchy-quattro.sh`:
  - New pre-apply step **"Snapper (re-apply safety)"**: when `/.snapshots`
    exists, `/etc/snapper/configs/root` does not and Omarchy's template is
    present, write the template config (and `SNAPPER_CONFIGS="root"`) — exactly
    the state upstream's stage ends in — so the failing `create-config` call is
    never reached. Decision: `snapper_reapply=template-written|not-needed`.
  - New `diagnose_apply_log`, called from the error trap after
    `diagnose_failure`: reports the `Failed: <script> (exit code: N)` lines
    that `/var/log/omarchy-install.log` gained since this run started
    (`APPLY_LOG_SEEN` is captured immediately before apply).
  - **"Bootloader reconciliation"**: on a non-limine machine, after disabling
    `limine-snapper-sync.service`, move `/boot/limine.conf`,
    `/boot/limine.conf.old` and `/boot/EFI/Linux/omarchy_*.efi` aside as
    `*.$BACKUP_SUFFIX` (recoverable; same treatment the Limine branch gives the
    config it rewrites). Decision: `limine_artifacts=moved-aside|none`.
- `tests/fixtures/cachyos-sdboot-luks`: the fixture now carries `/.snapshots/1`
  and `usr/share/omarchy/default/snapper/root`, and asserts
  `snapper_reapply=template-written` and `limine_artifacts=none`.

## Verification

- `tests/run.sh` → `256 passed, 0 failed` (matrix 114 passed); lint gate exit 0.
- `cachyos-sdboot-luks` pins both new branches: with `/.snapshots` present and
  no config, the dry run reports the template write; with no artefacts on
  `/boot`, it reports `none`.
- Guest (systemd-boot, minimal golden): the run that previously aborted at
  apply with no reason now reaches the end of the wrapper — sealing, initramfs
  rebuild and the assertion suite — after the three findings above were closed;
  the limine artefacts are moved aside instead of failing the suite.

## Considered and rejected

- **Tolerating apply-system's failure when the log shows only snapper.sh**:
  hides a real abort and leaves the machine without the config Omarchy expects;
  the pre-apply write produces the same end state without weakening the check.
- **Deleting the Limine artefacts**: `/boot` is a boot path; moves keep them
  recoverable, and the Limine branch already backs up the file it rewrites.
- **Touching `/usr/local/bin/mkinitcpio` or the packaged hooks**: plan 031's
  PATH pin already keeps the shim out of pacman transactions without editing
  packaged files; this plan only handles what the *service* leaves behind.
- **Reporting the artefacts and letting the user delete them**: the wrapper
  already asserts they must be gone, so failing while knowing the remedy is
  worse than applying the remedy.
