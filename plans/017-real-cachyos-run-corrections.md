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

## Second round: the GRUB CachyOS guest

A second guest (GRUB, LUKS2+btrfs, `systemd`/`sd-encrypt`, `rd.luks.uuid=`,
`[cachyos]` above `[core]`; evidence in
`~/Work/t1nk33r-lab-cachyos-grub/evidence/`) exercised the non-Limine path
against `c00d638`.

**The `HookDir` mechanism from plan 016 is now PROVEN, not reasoned.**
`pacman -S --debug linux-cachyos` on that guest:

```
debug: config: HookDir: /etc/pacman.d/hooks/
debug: config: HookDir: /etc/pacman.d/hooks-omocachy/
debug: parsing hook file /etc/pacman.d/hooks-omocachy/90-mkinitcpio-install.hook
debug: skipping overridden hook /etc/pacman.d/hooks/90-mkinitcpio-install.hook
debug: skipping overridden hook /usr/share/libalpm/hooks/90-mkinitcpio-install.hook
```

— with the same "skipping overridden" for all three `*limine*` hooks, the
initramfs still rebuilding on a kernel reinstall (mtime 01:45:24 → 01:50:38,
stock "Building image from preset"), `pacman -Qkk limine-mkinitcpio-hook`
reporting 56 files and 0 altered, and `limine-install` never running
(`BOOTX64.EFI` still byte-identical to GRUB's `grubx64.efi`). Three more
defects fell out of it.

### 2.1 `/usr/local/bin/mkinitcpio` bypasses the override one level down

`limine-mkinitcpio-hook` ships a PATH shim at `/usr/local/bin/mkinitcpio`, and
`/usr/share/libalpm/scripts/mkinitcpio` (line 237) calls `mkinitcpio
"${args[@]}"` **unqualified** — so the stock hook this project installs
resolved to the shim. The shim runs the real binary, then sees `-p` in the
args and prompts `run limine-mkinitcpio now? [Y/n]`; inside a pacman hook
stdin is at EOF, the empty answer takes the yes branch, and a GRUB machine
gets `/boot/limine.conf` (+`.old`) and a Limine UKI at
`/boot/EFI/Linux/omarchy_linux-cachyos.efi` written on **every** kernel
transaction. The guest deleted both, reinstalled the kernel, and they came
back. Not a boot hijack — but exactly the ESP litter the policy exists to
prevent, produced by the mechanism meant to prevent it.

**Fix:** the override hook's Exec is rewritten to
`Exec = /usr/bin/env PATH=/usr/bin /usr/share/libalpm/scripts/mkinitcpio install`,
pinning the lookup away from `/usr/local/bin`. The rewrite is verified after
it is applied (a future upstream Exec change makes the wrapper stop rather
than silently regress), asserted directly, and asserted again in end-state
form: no `/boot/limine.conf` and no `/boot/EFI/Linux/omarchy_*.efi` on a
non-Limine host.

### 2.2 The ERR trap fired inside subshells and ate its own output

`ssh_ports` piped `grep -iE '^\s*Port\s+[0-9]+' | awk`. A stock
`sshd_config` has only `#Port 22`, so grep exited 1; under `set -Ee` the ERR
trap fires **inside the process substitution**, printing a full "Error:
aborted at line N … " block and running `diagnose_failure`, which greps the
log for error patterns and therefore matched its own previous output. The
guest's log carried ~280 lines of nested false aborts. The run did not
actually abort (the trap's `exit` only killed the subshell), so the damage was
a terrifying, unreadable log — twice.

**Fix, both halves:** `ssh_ports` uses a single `awk` (no pipeline, no grep,
exits 0 on no match), and `on_err` returns early when `$BASHPID != $$`, so
only the main shell ever reports an abort. The second half is the general
guard — any future subshell failure now cannot produce that cascade.

### 2.3 `check_ufw_ssh` was a false FAIL

The ufw fix worked (`ufw allow 22/tcp` → "Rules updated", and
`/etc/ufw/user.rules` carries the tuple), but `firewall.sh` leaves ufw
`ENABLED=yes` with the unit *enabled and not started*, so until the next boot
`ufw status` prints "Status: inactive" and lists nothing. The assertion grepped
that empty listing and failed. **Fix:** read `ufw show added`, which reports
configured rules in either state.

Suite after these three: 124 assertions, 0 failures. Guest: 16/17 assertions
passed, the one FAIL being 2.3 above, and `tests/run.sh` ran 117/0 in the
guest before the install — confirming the test-stub fix holds on a
non-Omarchy host.

### 2.4 After the reboot: the ufw fix is proven end to end

ufw only becomes active at boot, so the enabled-not-started window (2.3) is
not where the fix is tested. After `systemctl reboot` on the GRUB guest, ssh
reconnected on the first attempt and `ufw status` reports **active**, `Default:
deny (incoming)`, with `22/tcp ALLOW IN Anywhere` (and its v6 form) alongside
Omarchy's own LocalSend and docker-DNS rules. `--verify-only` after the reboot:
rc=0, **18 PASS / 0 FAIL**, the ufw assertion among them. A 20-second
continuity poller recorded ssh-ok at every sample across the entire run
(01:44:36 → 01:52:43); the only failure in the series is the deliberate
reboot at 01:53:08. The serial console was never used.

### 2.5 Bootloader detection under a root-only ESP

Tested as an ordinary user, ESP file-state hash identical before and after
(nothing written). `mount -o remount,umask=…` is a no-op on vfat, so this
needed a real umount+mount:

| ESP mode | `bootctl` | verdict | source |
| --- | --- | --- | --- |
| `drwxr-xr-x` | present | `grub` | `bootctl LoaderInfo: GRUB 2.14` |
| `drwxr-xr-x` | hidden | `grub` | ESP contents (warns: "more than one bootloader … assuming grub") |
| `drwx------` | present | `grub` | `bootctl LoaderInfo: GRUB 2.14` |
| `drwx------` | hidden | `grub` | package probe, with its warning |

Three things this settles: GRUB 2.14 **does** set the systemd `LoaderInfo` EFI
variable, so tier 1 answers on a real GRUB machine before the ESP is read at
all and the mount mode is irrelevant; the multi-loader collision branch fires
for real here (because defect 2.1 had left a `/boot/limine.conf` behind) and
correctly picks `grub` with a warning; and in the genuinely worst case —
root-only ESP *and* no `bootctl` — it degrades to the package probe and still
answers `grub`, because `limine` is never probed. A GRUB machine is never
called a Limine host, which was the whole point of dropping the package test.

### 2.6 `ac62527` validated on a pristine GRUB guest, and one more assertion bug

Re-run from the pristine golden with all three round-two fixes: **19/19
assertions, exit 0**, `tests/run.sh` 118/0 in the guest, reboot back onto GRUB
and into the Omarchy greeter, `--verify-only` 19/19 after it.

- 2.1 holds, and this is the decisive evidence. The override's Exec on the
  guest is the PATH-pinned form; `pacman -S --debug linux-cachyos` shows the
  hooks-omocachy hook parsed and all five others "skipping overridden", the
  initramfs rebuilding (mtime 01:59:40 → 02:01:28), and **no** "does not
  update Limine boot entries", no "Building UKI", no `limine.conf`, no
  `EFI/Linux`. `find /boot -iname 'limine*' -o -path '*EFI/Linux*'` is empty
  before and after. On `c00d638` the same command produced both every time.
- 2.2 holds: zero "aborted at line" blocks and no nested `diagnose_failure`
  output, with the same four Port-less `sshd_config` drop-ins (1196 log lines
  against 1391, ~280 of which had been noise).
- 2.3 holds and is *live*, not inert: `sudo -n ufw show added` returned rc=0
  and printed `ufw allow 22/tcp` with no password prompt, so the assertion is
  really asserting on that guest.
- The multi-loader collision warning is gone on a clean install
  (`bootloader_source=ESP contents under /boot`, no "also found"), confirming
  the `/boot/limine.conf` in §2.5 was 2.1's litter and that the PATH pin
  covers every path that wrote it.

**Defect 2.6 (mine, in the new assertion).** `check_no_limine_artifacts` ran
`sudo -n sh -c 'ls -1 …'` and inferred "cannot read /boot" from a non-zero
exit. But `ls` with no matches exits 2 — which is the **success** case — so on
a readable `/boot` with no artefacts it printed "(/boot is not readable
without a password)" and passed for the wrong reason. It still failed
correctly when artefacts existed, so it was never inert, but it could not
distinguish clean from unreadable, which is precisely what the note claimed.
Fixed by probing the capability separately (`can_sudo_quietly`, a bare
`sudo -n true`) and letting the command's own empty output mean "nothing
found". The same inference was wrong in `check_ufw_ssh` and
`check_limine_cmdline_args`; all three now use the shared probe, and the
latter distinguishes "no readable limine.conf" from "limine.conf without
`initramfs_async=0`".

## Still unverified

1. ~~The non-Limine `HookDir` mechanism has not been exercised in a real
   pacman transaction.~~ **RESOLVED** by the GRUB guest above: pacman's own
   `--debug` output shows both HookDir lines, the override parsed and all four
   shadowed hooks "skipping overridden", with the initramfs still rebuilding
   and `-Qkk` clean. This was the last mechanism resting on `pacman.conf(5)`
   alone.
2. ~~The round-two fixes have not been run on a guest.~~ **RESOLVED** for
   2.1–2.3 by the pristine `ac62527` run in §2.6 (19/19, kernel reinstall
   produced no Limine artefacts, clean log, live ufw assertion). What is left
   is **defect 2.6's own fix**, which is dry-run and host-`--verify-only`
   verified only — on the maintainers' host the three checks now correctly
   report "needs passwordless sudo" instead of claiming /boot is unreadable,
   but that is the *degraded* branch. The GRUB guest has NOPASSWD, so a re-run
   there is what proves the non-degraded branch still distinguishes clean from
   dirty.
3. **systemd-boot** is still untested. GRUB was the guest that got built; the
   systemd-boot branch differs only in detection, which the fixture covers.
4. **`sudo`-side `OMARCHY_PATH`.** `/etc/environment` is applied by `pam_env`;
   whether `sudo omarchy update` picks it up depends on the sudo PAM stack and
   `env_reset`, so the documented answer is "run it as your user", not a claim
   that sudo now works.
