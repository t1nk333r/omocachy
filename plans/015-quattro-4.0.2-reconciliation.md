# Plan 015: Reconcile `bin/install-omarchy-quattro.sh` against Omarchy 4.0.2

> **Executor instructions**: This plan was executed in the same session it
> was written; the "Changes" section is the record of what landed and why.
> Every upstream claim below was verified against an installed Omarchy 4.0.2
> (`omarchy 4.0.2-1`, `omarchy-settings 4.0.2-1`, `limine-mkinitcpio-hook
> 1.37.1-1`, `mkinitcpio 41.1-1`, `limine 12.6.0-1`) by reading the package
> files on disk, not from a git checkout or the raw CDN. Re-verify against
> the installed version before touching any step; the file:line references
> are to `/usr/share/omarchy/**`, `/usr/bin/omarchy-*` and
> `/var/lib/pacman/local/*/install` on such a host.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: HIGH if wrong (initramfs / bootloader / login state on a LUKS
  machine) — mitigated by dry-run content printing, a transform that keeps
  Omarchy's array as the base, and the assertion suite
- **Depends on**: plan 012 (the wrapper this reconciles)
- **Category**: correctness
- **Planned at**: omacachy `e5b5a1c` (Rename project branding to omacachy),
  2026-09-06; upstream stamp: omarchy **4.0.2-1**
- **Status**: DONE (this session; dry-run verified on the dev machine —
  Omarchy 4.0.2 ISO install, Limine, LUKS, AMD; **never run for real on a
  CachyOS host**, see release gate 1 in `handoff.md`)

## Why this matters

Plan 012 was designed against v4.0.0 from static analysis. Auditing the
wrapper against an installed 4.0.2 found that three of its reconciliation
steps were wrong in ways that would leave a CachyOS machine unbootable or
un-updatable, and that five things 4.0.2 does to a host were not handled at
all. mroboff/omarchy-on-cachyos issue #74 independently reports most of
these from a real CachyOS attempt.

## Findings and the upstream evidence

### F1. Bootloader detection was tautological after the first run

`pacman -Qq limine` was the first probe. `pacman -Qi omarchy` → `Depends On:
... limine limine-mkinitcpio-hook limine-snapper-sync ...`, so once omarchy is
installed every machine "has limine"; a GRUB CachyOS box re-running the wrapper
would have skipped the non-Limine branch.

**Fix**: ask the firmware first — `bootctl status | grep -m1 'Product:'`
reads the LoaderInfo EFI variable without root (verified on the dev host:
`Product: Limine 12.6.0`; systemd-boot sets it too, GRUB does not), then
readable `/boot/limine.conf`, `/boot/grub/grub.cfg`, `/boot/loader/loader.conf`,
then `pacman -Qq grub` / `bootctl is-installed`, and only last the limine
package with a printed caveat. The plan summary prints the source. A re-run
with omarchy already installed is announced as a re-apply.

### F2. The HOOKS `zz-` re-assert was lossy and, on CachyOS, wrong-flavoured

`/etc/mkinitcpio.conf.d/omarchy_hooks.conf` (omarchy-settings, `%BACKUP%`)
line 1:

```
HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck btrfs-overlayfs)
```

and lines 18-43 conditionally remove `kms` when `nvidia_drm` is early-loaded
and NVIDIA owns every display controller. The old wrapper wrote
`HOOKS=(<captured>)` after it, which (i) dropped `plymouth` — a hard
dependency of omarchy-settings whose `default/limine` cmdline
(`/etc/limine-entry-tool.d/omarchy-defaults.conf`: `quiet splash ...`)
expects the hook, (ii) dropped `btrfs-overlayfs` (snapshot boot), (iii)
re-added `kms` on NVIDIA-only machines, and (iv) on a CachyOS capture would
have re-asserted a systemd array while Omarchy's udev array was the one the
rest of the drop-ins assume. Separately, #74: CachyOS boots LUKS with
`rd.luks.uuid=` which only `sd-encrypt` honours, so Omarchy's `encrypt` array
is unbootable at the next rebuild.

Verified supporting facts: `pacman -Ql limine-mkinitcpio-hook` ships both
`/usr/lib/initcpio/install/btrfs-overlayfs` and
`/usr/lib/initcpio/install/sd-btrfs-overlayfs`; `/usr/lib/initcpio/install/plymouth:77-89`
has an `add_systemd_unit` branch, so plymouth works in a systemd initramfs;
`sd-encrypt` and `sd-vconsole` are in `/usr/lib/initcpio/install/` (systemd).

**Fix**: `zz-cachyos-keep-hooks.conf` is now bash logic that *transforms* the
array Omarchy set: (a) when the captured array was systemd-flavoured
(`systemd`/`sd-encrypt`/`sd-vconsole` present) map `udev→systemd`,
`encrypt→sd-encrypt`, `keymap consolefont→sd-vconsole`,
`btrfs-overlayfs→sd-btrfs-overlayfs`, and drop the udev-only `usr`/`resume`
unless captured; (b) re-add every captured hook still missing — block-level
ones (`lvm2 mdadm_udev ... resume usr`) before `filesystems`, others at the
end; (c) never re-add `kms`. The captured array is embedded as a literal with
the rationale as a header comment, and `--dry-run` prints the rendered file.
The LUKS pre-flight abort accepts `encrypt` or `sd-encrypt` as words.
Verified with a throwaway harness on four captures (systemd+lvm2,
systemd+resume, udev+lvm2, udev no LUKS), each against Omarchy's array with
and without `kms`, with and without `omarchy_resume.conf`'s `HOOKS+=(resume)`.

### F3. The limine-hook "no-op override" disabled initramfs regeneration

`pacman -Ql limine-mkinitcpio-hook` ships four hooks:
`/etc/pacman.d/hooks/90-mkinitcpio-install.hook` (Exec
`/usr/share/libalpm/scripts/limine-mkinitcpio-install`),
`/usr/share/libalpm/hooks/60-limine-mkinitcpio-remove-pre.hook`,
`/usr/share/libalpm/hooks/80-limine-efi-deploy.hook` (Exec `limine-install`),
`/usr/share/libalpm/hooks/90-limine-mkinitcpio-remove-post.hook`. The first
is package-owned *inside* `/etc/pacman.d/hooks` and, by living there, already
shadows mkinitcpio's stock `/usr/share/libalpm/hooks/90-mkinitcpio-install.hook`
(owned by `mkinitcpio 41.1-1`). Writing `Exec = /usr/bin/true` over it on
non-Limine machines therefore switched off initramfs rebuilds on kernel,
firmware and DKMS upgrades — and the file is not in `%BACKUP%`, so the next
package upgrade would silently restore the Limine variant anyway.

**Fix**: on non-Limine hosts copy the stock mkinitcpio hook over
`/etc/pacman.d/hooks/90-mkinitcpio-install.hook` and add `NoUpgrade =
etc/pacman.d/hooks/90-mkinitcpio-install.hook` under `[options]` in
`/etc/pacman.conf` (pacman.conf(5): the upgraded package's file becomes a
`.pacnew`). The other three are overridden by same-named no-ops in
`/etc/pacman.d/hooks/`, which is the documented override path for hooks in
`/usr/share/libalpm/hooks`. `limine-snapper-sync.service` is still disabled.
The assertion suite accepts exactly that one altered file in `pacman -Qkk
limine-mkinitcpio-hook` on non-Limine hosts and requires a clean report on
Limine.

### F4. Final rebuild used the interactive wrapper

`/usr/local/bin/mkinitcpio` is owned by limine-mkinitcpio-hook and, after
`-P`, prompts `Would you like to run 'limine-mkinitcpio' now? [Y/n]` — a
`--yes` run would hang. **Fix**: `limine-mkinitcpio` on Limine,
`/usr/bin/mkinitcpio -P` (absolute) otherwise.

### F5. Host identity and services were rewritten and not restored

`/var/lib/pacman/local/omarchy-settings-4.0.2-1/install`, `_etc_overrides_apply`
(runs from both `post_install` and `post_upgrade`):

```
rm -f /etc/os-release
cp -f /usr/share/omarchy/etc-overrides/os-release              /etc/os-release
cp -f /usr/share/omarchy/etc-overrides/security-faillock.conf  /etc/security/faillock.conf
cp -f /usr/share/omarchy/etc-overrides/nsswitch.conf           /etc/nsswitch.conf
```

(`etc-overrides/os-release` is `ID=omarchy ID_LIKE=arch`). Also
`install/config/snapper.sh:18-22` writes `/etc/conf.d/snapper` to
`SNAPPER_CONFIGS="root"` and `systemctl disable --now snapper-timeline.timer`;
`install/hardware/network.sh:2` `systemctl disable iwd.service`.

**Fix**: timestamped backups of `/etc/os-release`, `/etc/nsswitch.conf`,
`/etc/conf.d/snapper` (and `/boot/limine.conf` on Limine) before the pacman
transaction; restore after `omarchy-apply-system`; re-enable
`snapper-timeline.timer` if it was enabled; re-enable `iwd.service` only when
NetworkManager has `wifi.backend=iwd`. Because the scriptlet re-fires on every
upgrade, the CachyOS copies are also kept in `/etc/cachyos-preserved/` and a
PostTransaction hook `/etc/pacman.d/hooks/zz-cachyos-preserve-etc.hook`
(Target `omarchy-settings`, Install/Upgrade, Exec `cp -f -t /etc ...`)
restores them after each one. The preserved copies are only taken from a host
whose `/etc/os-release` is not yet `ID=omarchy`. `faillock.conf` is left to
Omarchy: `install/config/increase-lockout-limit.sh` pairs it with PAM edits.
`/boot/limine.conf` is only restored (then `limine-update`) right after
`omarchy-reinstall-configs`, because that is the only thing that replaces it
(`omarchy-reinstall-configs:23` → `omarchy-refresh-limine:14-18`: `mv
/boot/limine.conf /boot/limine.conf.bak; cp default/limine/limine.conf
/boot/limine.conf; limine-update; limine-snapper-sync`, no bootloader check).

### F6. Limine entry-tool defaults switch CachyOS to UKI and rename the OS

omarchy-settings ships `/etc/limine-entry-tool.d/omarchy-defaults.conf`
(`TARGET_OS_NAME="Omarchy"`, `BOOT_ORDER="*, *fallback, Snapshots"`,
`CUSTOM_UKI_NAME="omarchy"`, `MAX_SNAPSHOT_ENTRIES=6`, `splash` cmdline) and
`omarchy-uki.conf` (`ENABLE_UKI=yes`). `/usr/lib/limine/limine-common-functions:98-132`
`load_config` loads `/usr/share/limine-entry-tool.d/*.conf`, then
`/etc/limine-entry-tool.conf`, then `/etc/limine-entry-tool.d/*.conf`, then
`/etc/default/limine` **last** ("highest priority"). #74: the OS name
mismatch makes `limine-snapper-sync` abort.

**Fix**: on a Limine host append a delimited block to `/etc/default/limine`
with only the keys it does not already set: `TARGET_OS_NAME="CachyOS"`
(CachyOS hosts only), `ENABLE_UKI=no`, `BOOT_ORDER="*, *lts, *fallback,
Snapshots"` when `linux-cachyos-lts` is installed, else without `*lts`.
Written before the pacman transaction so the first `limine-update` already
uses it. `MAX_SNAPSHOT_ENTRIES` and `KERNEL_CMDLINE` are left alone.

### F7. No way to keep the wrapper out of `$HOME`; login state unhandled

`omarchy-reinstall-configs:21` does `cp -af /etc/skel/. ~/`; `omarchy-provision-user
--first-install` at runtime forces `OMARCHY_SETUP_CONTEXT=iso-chroot`
(`omarchy-provision-user:69-73`) and `install/user/mise-work.sh:16,25-27` then
hard-fails on the missing ISO `/opt/packages` Node tarball (#74). Upstream
4.0.2 ships only `sddm.conf.d/10-theme.conf` and `10-wayland.conf`;
`install/login/sddm.sh` only trims PAM lines; `autologin.conf` and
`99-omarchy-login.conf` on an ISO install are owned by no package. The Omarchy
SDDM theme has no username field (#74), so a fresh CachyOS without a
remembered user cannot log in.

**Fix**: `--skip-user-configs` skips the skel backup, `omarchy-reinstall-configs`,
`omarchy-provision-user`, the fish conf.d file, and (via
`OMACACHY_SKIP_USER_CONFIGS=1`) any GPU-script write into `$HOME`. Without
the flag, `omarchy-provision-user --first-install` runs with
`OMARCHY_SETUP_CONTEXT=provision-owner` (the first-boot path: same
first-install marking, headless theme set, Node from the network with a
warning instead of an abort). Always written: `/etc/sddm.conf.d/99-omarchy-login.conf`
(`[Users] RememberLastUser=true RememberLastSession=true`, shape copied from
the dev host) and, if absent, `/var/lib/sddm/state.conf` (`[Last]
User=$USER Session=/usr/local/share/wayland-sessions/omarchy.desktop`, shape
per #74 — the dev host's copy is root-only and was not read; the existence
test and the write run together under one `run_root sh -c` because
`/var/lib/sddm` is `sddm:sddm 0750`). `--autologin` (default off) writes
`/etc/sddm.conf.d/autologin.conf` (`[Autologin] User=$USER
Session=omarchy.desktop`, shape from the dev host).

### F8. GPU scripts appended to the user's `~/.config/uwsm/env`

`uwsm(1)` CONFIGURATION lists `uwsm/env` and `uwsm/env.d/*` in the XDG config
hierarchy as sourced for the session, and upstream's own
`default/uwsm/env.d/10-omarchy:6-7` says user overrides belong "preferably,
[in] ~/.config/uwsm/env.d/*". **Fix**: `amd-rocm.sh`/`nvidia.sh` write
`~/.config/uwsm/env.d/50-omacachy-gpu` (a file they own and rewrite), or with
`OMACACHY_SKIP_USER_CONFIGS=1` print the lines and write nothing.

### F9. The update guard blocks direct `pacman -Syu` afterwards — including re-runs

`/usr/share/libalpm/hooks/00-omarchy-update-guard.hook` (owned by `omarchy`,
PreTransaction, `AbortOnFail`, `Depends = omarchy`) runs
`omarchy-update-pacman-guard`, which at line 8 passes only with
`OMARCHY_UPDATE_PACMAN=1` or `OMARCHY_ALLOW_DIRECT_PACMAN=1`. **Fix**: the
wrapper's own `pacman -Syu` runs under `OMARCHY_ALLOW_DIRECT_PACMAN=1` (needed
on re-apply, harmless on first install), and the closing message tells the
user to use `omarchy update` or that variable.

### Assertion suite additions

`ID=cachyos` in `/etc/os-release` on CachyOS hosts; `[cachyos` repo still
present; `pacman -Qkk limine-mkinitcpio-hook` clean (Limine) or only the
NoUpgrade-managed hook (non-Limine); the drop-in exists and the *effective*
HOOKS (re-sourced the same way as the capture) keep the captured LUKS flavour,
`plymouth`, and `btrfs-overlayfs`/`sd-btrfs-overlayfs`; `/etc/default/limine`
has `TARGET_OS_NAME` on a CachyOS Limine host; the existing `sddm.conf`,
services, snapper and `omarchy` CLI checks. Assertions are now functions
(`check_*`) so descriptions are not duplicated between dry-run and real mode.

## Still unverified

- Every step above on a **real CachyOS** host (release gate 1). The dev
  machine is an Omarchy ISO install: `IS_CACHYOS=false`, `ID=omarchy`, udev
  flavour, so the CachyOS-specific branches (systemd mapping, preserve hook,
  `TARGET_OS_NAME`) were exercised only by the harness and dry-run.
- Whether CachyOS ships an `/etc/default/limine` at all, and whether its
  `/boot` is 0700 (affects the `/boot/limine.conf` backup warning path).
- `/var/lib/sddm/state.conf` shape is from #74, not read from a host.
- Whether `nsswitch.conf` restoration interacts with Omarchy's enabled
  `systemd-resolved` on CachyOS (CachyOS also uses resolved per
  cachyos-settings, so the stock `resolve` line should already be there).
