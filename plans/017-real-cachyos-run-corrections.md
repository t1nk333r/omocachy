# Plan 017: Corrections from the first real CachyOS run

> **Executor instructions**: Written and executed in the same session as the
> run it records. Every defect below was observed on a **real CachyOS 260809
> guest** (LUKS2 + btrfs + Limine, `~/Work/t1nk33r-lab-cachyos`, evidence in
> that directory's `evidence/`), not derived from reading packages. Where a
> claim is still only reasoned, it says so.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: HIGH (one of the three defects locked a machine out of ssh
  mid-install; another left the wrapper unable to finish unattended)
- **Depends on**: plan 016
- **Category**: correctness
- **Planned at**: omocachy `2b5fa74`, 2026-09-07
- **Status**: DONE. Fixes are dry-run and fixture verified; **the fixes
  themselves have not been re-run on the guest yet**, and the non-Limine
  `HookDir` mechanism from plan 016 remains unproven in a real transaction
  (see "Still unverified").

## What the real run proved (plan 016 holding up)

Recorded because it is the first evidence any of this works outside a fixture:
13/13 assertions passed, the machine rebooted into the Omarchy greeter, and

- `/etc/default/limine` precedence is exactly as documented
  (`/usr/share/limine-entry-tool.d` → `/etc/limine-entry-tool.conf` →
  `/etc/limine-entry-tool.d/*.conf` → `/etc/default/limine` **last**). The
  block beat `omarchy-defaults.conf`'s `TARGET_OS_NAME="Omarchy"` and
  `omarchy-uki.conf`'s `ENABLE_UKI=yes`, correctly omitted `*lts` with no LTS
  kernel present, created the file (pristine CachyOS has none), survived
  apply-system + `limine-mkinitcpio` + reboot + a partial `omarchy update`,
  and was idempotent on re-apply.
- `pacman -Qkk limine-mkinitcpio-hook` is **clean** — the plan 016 decision to
  stop editing packaged files paid off as intended.
- The preserve hook fired again on an `omarchy-settings` reinstall: the repeat
  case that could not be tested before. `/etc/os-release` stayed `ID=cachyos`.
- CachyOS Calamares confirms the core assumption from the ISO itself, not by
  inference: `initcpiocfg` has `useSystemdHook: true` and appends `sd-encrypt`
  (`main.py:184`), and `bootloader/main.py:175` emits
  `rd.luks.uuid=<uuid>` + `root=/dev/mapper/<name>` (line 177 is the
  `cryptdevice=UUID=` fallback). This is fixture `cachyos-limine-luks`.

## Defect 1 — the wrapper could not complete unattended

`omarchy-apply-system` enables and calls things the Omarchy **ISO** has
already installed but the `omarchy` **package** does not depend on. Each is a
hard abort; the guest hit them one per re-run, in this order:

| stage | failure | package |
| --- | --- | --- |
| `install/config/enable-services.sh` | `Unit cups.service does not exist` (exit 1) | `cups` |
| `install/config/enable-services.sh` | `Unit linux-modules-cleanup.service does not exist` | `kernel-modules-hook` (`pacman -F` → `extra/kernel-modules-hook 0.1.7-3`) |
| `install/config/firewall.sh` | `ufw: command not found` (exit 127) | `ufw` |
| `install/config/firewall.sh` | empty `command -v ufw-docker`, so its `sed "$ufw_docker_bin"` fails | `ufw-docker` |
| `install/hardware/bluetooth.sh` | `Unit bluetooth.service does not exist` | `bluez`, `bluez-utils` |
| `install/post-install/localdb.sh` | `updatedb: command not found` (exit 127) | `plocate` |

`docker.socket` and `power-profiles-daemon.service` are in the same
`enable-services.sh` list and would have failed next; `avahi-daemon.service`
is too, and only passed because pristine CachyOS happens to ship `avahi`.

**Fix:** `OMARCHY_ISO_CLOSURE` (`cups avahi docker power-profiles-daemon
kernel-modules-hook ufw ufw-docker bluez bluez-utils plocate`) is installed in
the **same transaction** as the omarchy packages — it cannot be earlier,
because `ufw-docker` lives in `[omarchy]` and that stanza is added by this
script. Then a **pre-apply gate** (`APPLY_REQUIREMENTS`) asserts every unit
and command the apply stages call actually exists and stops naming the missing
package, rather than discovering it halfway through an apply. Two new
assertions cover both. Apply failures are *not* ignored anywhere.

## Defect 2 — Omarchy's firewall config is an ssh lockout

`install/config/firewall.sh` does `ufw default deny incoming`, `ufw default
allow outgoing`, two LocalSend rules and the docker-DNS rules, flips
`ENABLED=yes` in `/etc/ufw/ufw.conf` and enables the unit — **no ssh allowance
anywhere**. Because `ENABLED=yes` is already set when the `ufw` invocations
run, the rules load into the running kernel immediately: the guest's ssh
session died *during* apply-system, with `systemctl is-active ufw` still
reporting inactive and `ufw status verbose` reporting `Status: active /
Default: deny (incoming)`. Recovery needed the hypervisor console. Every
CachyOS box someone layers Omarchy onto over ssh is this machine.

`waydots` survives it only incidentally, because its `packages/ufw.txt`
carries `22/tcp`; the wrapper alone did not.

**Fix (decision: allow, do not refuse):** before apply-system, when an sshd is
enabled, the wrapper reads the port(s) from `/etc/ssh/sshd_config` **and**
`/etc/ssh/sshd_config.d/*.conf` (a drop-in is the normal shape — the guest has
one) and runs `ufw allow <port>/tcp` for each, printing a loud `!!` block
saying it did and why. ufw rules written before it is enabled persist in
`/etc/ufw/user.rules`, which is exactly how the clean end-to-end run survived.
With no sshd enabled, nothing is opened and the run says so, with the command
to run if sshd is enabled later. Refusing to enable ufw was rejected: it would
leave a machine the user believes is firewalled unfirewalled, which is a worse
failure than an open ssh port the user already exposes.

## Defect 3 — `omarchy update` was broken on exactly the hosts `--skip-user-configs` creates

`omarchy update` → `omarchy-update-dev`, line 7:

```sh
[[ $OMARCHY_PATH != "/usr/share/omarchy" ]] || exit 0
```

under `set -euo pipefail`. The guard itself is what trips: with the variable
unset it dies `OMARCHY_PATH: unbound variable`. The only thing exporting it is
`/usr/share/omarchy/default/bash/env-bootstrap:14`, sourced from the packaged
`/etc/profile.d/omarchy.sh` (**login shells only**) and `/etc/skel/.bashrc` —
the file `--skip-user-configs` deliberately does not replay. `sudo omarchy
update` fails the same way (root has no `OMARCHY_PATH` either), and the
root-owned `/tmp/omarchy-update.log` it leaves then blocks the user's next
attempt with `script: cannot open /tmp/omarchy-update.log: Permission denied`.

With the variable set by hand the update proceeds and stops on a migration:

```
Running migration (1785608166)
Repair the pre-suspend lock monitor's graphical session environment
Could not reset omarchy-sleep-lock.service: ... Unit omarchy-sleep-lock.service not loaded.
The pre-suspend lock repair will be retried by omarchy-migrate.
```

Nothing regressed after that partial update (os-release still `cachyos`,
`[cachyos]` above `[core]`, HOOKS unchanged, `-Qkk` clean, 13/13 assertions) —
a usability break, not corruption.

**Fix:** `OMARCHY_PATH=/usr/share/omarchy` is added to `/etc/environment`,
read by `pam_env` at session setup, so it reaches every shell (fish included),
ssh sessions and the graphical session — **without touching `$HOME`**, so the
flag's contract holds. Skipped when `/etc/omarchy.conf` exists, because
`omarchy-dev-link` owns the variable then and `env-bootstrap` must stay
authoritative. It applies at next login, so the final message also prints the
current-session form (`OMARCHY_PATH=/usr/share/omarchy omarchy update`), says
to run the update as the user rather than with sudo, documents the
`/tmp/omarchy-update.log` trap, and documents the sleep-lock migration as
expected noise. New assertion covers the drop-in.

## Also corrected from the run

- **`/etc/cachyos-release` does not exist on an installed CachyOS 260809** —
  unowned, `pacman -F` finds no package shipping it; it lives only on the live
  ISO. Detection now leads with the `^\[cachyos` pacman.conf grep and keeps the
  release file as a secondary hint. Fixtures updated to match (only
  `cachyos-grub-plain` still carries the file, so the hint stays covered).
- **`KERNEL_CMDLINE` in `/etc/default/limine`.** That file loading last is
  what makes it the right override point and also means a plain
  `KERNEL_CMDLINE[default]=` there *replaces* what `omarchy-settings` appends
  with `+=` — on the guest that dropped the splash arguments and
  `initramfs_async=0`, whose upstream comment says an encrypted boot otherwise
  falls back to an unthemed text LUKS prompt. The wrapper does not set
  `KERNEL_CMDLINE`, but it now (a) warns when it finds the `=` form, (b) writes
  a "MUST use `+=`" comment into its own block, since that block is the
  last-loaded place someone will later add a cmdline line, and (c) asserts
  `initramfs_async=0` survives into the **generated** `/boot/limine.conf` on a
  LUKS Limine host. It does not rewrite anyone's kernel command line.
- **Test bug found by running the suite in the guest** (`100 passed, 1
  failed`): `grub host: refresh-limine shadowed, replay still runs` failed
  because that message is printed inside `if command -v
  omarchy-reinstall-configs`, which does not exist on a host without Omarchy —
  so the branch was never reached, and the assertion had been passing on the
  maintainers' Omarchy box *for the wrong reason*. `tests/run.sh` now puts
  inert stubs for `omarchy-reinstall-configs`, `omarchy-provision-user` and
  `omarchy-refresh-limine` first on `PATH` for the matrix runs; they exit 97
  loudly if a dry run ever actually executes one. Suite: 123 assertions, 0
  failures.

## Still unverified

1. **The non-Limine `HookDir` mechanism (plan 016) has NOT been exercised in a
   real pacman transaction.** The guest is Limine, so both `643bb57` and
   `2b5fa74` take `boot_hook_policy=limine-native` and are indistinguishable
   there. `pacman.conf(5)` is still the only source for "later HookDir wins"
   and "naming any HookDir replaces the `/etc/pacman.d/hooks` default". This
   needs a GRUB or systemd-boot CachyOS guest, and it must show: both HookDir
   lines present; `limine-install` never running and no Limine EFI binary
   appearing on the ESP; the initramfs still rebuilding on a kernel
   install/reinstall (the failure mode the old no-op caused); `pacman -Qkk`
   clean; bootloader detected from ESP contents while the `limine` package is
   installed as an omarchy dependency.
2. **These three fixes have not themselves been run on the guest.** They are
   dry-run and fixture verified only. `./lab reset` + a re-run is the next
   step.
3. **`sudo`-side `OMARCHY_PATH`.** `/etc/environment` is applied by `pam_env`;
   whether `sudo omarchy update` picks it up depends on the sudo PAM stack and
   `env_reset`, so the documented answer is "run it as your user", not a claim
   that sudo now works.
