# Handoff — omacachy

Orientation for whoever (human or agent) picks this project up next.
Updated 2026-09-11. User-facing docs live in
`README.md`; the full engineering record lives in `plans/` — this file is
the map between them.

## What this repo is now

A standalone project (fork of `mroboff/omarchy-on-cachyos`, **not**
PR-bound — clone URLs point at `d7eeem/omocachy`; `FUNDING.yml` deliberately still
credits the original author). It installs Omarchy 4 on CachyOS with a
per-item debloater, and carries an existing Omarchy desktop profile onto the
new machine:

| Component | Script | State |
|---|---|---|
| Omarchy 4 "Quattro" package wrapper | `bin/install-omarchy-quattro.sh` | Reconciled against installed 4.0.2 (plan 015), backed by a fixture matrix (`tests/run.sh`, plan 016) and **run end to end on real CachyOS guests: Limine, Limine+LUKS2 (root converted in place) and GRUB** (plans 016/017); systemd-boot is fixture-only |
| v4 per-item debloat picker | `bin/debloat-quattro.sh` | Built, mock-verified, needs real-v4 TUI run |
| Profile migration (export → import → doctor) | `bin/omacachy-profile-export.sh`, `bin/omacachy-profile-import.sh`, `bin/omacachy-doctor.sh` | Plan 018. Exercised end to end for real in the Omarchy lab VM (export, import onto a pristine guest, screenshot of the migrated desktop, `./lab test` green, rollback, re-import); the `packages` and `mise` stages ran online against a real CachyOS guest |
| Shared helpers | `bin/lib/common.sh`, `bin/lib/profile.sh`, `share/profile-paths.conf` | `common.sh` is the dry-run contract shared by the profile scripts; `profile.sh` owns bundle schema 1 and the exclude/secret/package policies |
| GPU dispatch | `bin/gpu-detect.sh` → `gpu-setup.sh` → `nvidia.sh`/`amd-rocm.sh` | Working; NVIDIA probes the PCI id for the generation and warns on the one broken combination (open module, pre-Turing), installs `nvidia-vaapi-driver`, and writes a `modeset=1` drop-in only when nothing else sets one; AMD is VA-API-only; session env goes to `~/.config/uwsm/env.d/50-omacachy-gpu`, never `~/.config/uwsm/env`; all honour `--dry-run` |

## Version policy

`main` supports Omarchy 4 only. The complete legacy Omarchy 3 implementation
is preserved on the local `v3` branch, created at `f32b850`; keep any legacy
maintenance isolated there and do not reintroduce those scripts to `main`.

## How this got here (compressed history, 2026-08-17 → 08-19)

1. Rebased the fork onto upstream `mroboff` main, then ran a full advisor
   audit → 14 plans, all executed in isolated worktrees with reviewed diffs.
   `plans/README.md` has the status table.
2. Load-bearing discoveries (each recorded in the relevant plan file):
   - **Omarchy v4.0.0 removed `install.sh` entirely** — v4 = Arch packages
     (`omarchy`, `omarchy-settings`, `omarchy-keyring`) applied by
     `omarchy-apply-system` from an ISO chroot, `OMARCHY_PATH=/usr/share/omarchy`.
   - v4's post-install **clobbers `/etc/pacman.conf` AND
     `/etc/pacman.d/mirrorlist`**; `omarchy-settings` ships an mkinitcpio
     `HOOKS` override that can **break LUKS boot**; `omarchy` hard-depends
     on limine/plymouth. The wrapper's whole job is reconciling these
     (backups, `zz-cachyos-keep-hooks.conf`, pacman-hook no-op override for
     non-Limine machines, assertion suite).
   - `chwd -a amd-gpu` had been a silenced no-op for its entire life
     (classid vs profile-name confusion); now `chwd -i amd`. Mesa dropped
     VDPAU upstream (Sept 2025) — never re-add `mesa-vdpau`/`VDPAU_DRIVER`.
   - **raw.githubusercontent.com served stale content** for basecamp/omarchy
     during the audit. Verify upstream facts via `git clone`/`ls-remote`;
     tag- or commit-addressed raw URLs are acceptable, branch paths are not.
3. README fully rewritten (Quattro-first, factored sections) 2026-08-19.
4. 2026-09-06: the wrapper was audited against an *installed* Omarchy 4.0.2
   (plan 015). Three plan-012 steps were wrong — bootloader detection via
   `pacman -Qq limine` (tautological: omarchy depends on limine), the
   wholesale HOOKS re-assert (dropped plymouth/btrfs-overlayfs, wrong
   flavour for CachyOS's `rd.luks.uuid=` boot), and the `/usr/bin/true`
   override of `90-mkinitcpio-install.hook` (which is the *only* active
   mkinitcpio install hook once limine-mkinitcpio-hook is present, so it
   switched off initramfs rebuilds). All replaced; see the plan for evidence.
5. 2026-09-07/08: the first real CachyOS guests — Limine, then GRUB, then
   the Limine guest with its root converted to LUKS2 in place (`./lab
   rescue`, `cryptsetup reencrypt`, `sd-encrypt` + `rd.luks.uuid=`) —
   produced the plan-017 corrections, the LUKS boot evidence and the profile
   migration (plan 018). 2026-09-11: the two parallel work lines
   (wrapper/tests on `main`, profile/LUKS on `omacachy`) were consolidated
   into one branch.

## Working conventions (keep these)

- **Follow Omarchy's native interfaces**: the Quattro picker derives its
  candidate lists and removal behavior from the installed Omarchy scripts,
  with MIT attribution in its header.
- **Plan → executor → review**: plans in `plans/NNN-*.md` are self-contained
  for a zero-context executor, stamped with the commit they were written
  against (drift-check first). Executors run in isolated git worktrees; the
  reviewer re-runs done criteria, reads the whole diff, then fast-forwards
  main. Never merge a worktree branch while your shell's cwd is inside it.
- **Lint gate**: `bash -n bin/*.sh bin/lib/*.sh tests/run.sh` plus
  `shellcheck --severity=warning -x bin/*.sh bin/lib/*.sh tests/run.sh`
  (`-x` so the sourced `bin/lib/` helpers are followed; shellcheck 0.11
  locally, CI at `--severity=error` via the `Jenkinsfile`). Run it before
  every push, and `tests/run.sh` before and after touching the wrapper.
- Every state-changing script offers `--dry-run`; privileged ops flow
  through `run`/`run_root`-style helpers so dry-run is enforceable by grep.

## CI / infrastructure (lives OUTSIDE this repo, on the dev machine)

`~/Documents/gh-runner/` — docker compose stack (docker socket mounted =
root-equivalent; secrets in `.env`, unrecoverable, never commit or print):

- 3 ephemeral GitHub Actions runners (`d7eeem/feather`,
  `d7eeem/omocachy`, `d7eeem/garage-webui-ng`). Note: this repo's
  Actions workflow was **removed** in favor of Jenkins, so `runner-omarchy`
  currently serves nothing — keep or retire deliberately.
- 1 Jenkins inbound agent (`docker-host` → `http://10.10.10.62:8080`,
  websocket). **Currently failing its handshake — almost certainly a stale
  `JENKINS_AGENT_SECRET`**; fix = copy a fresh secret from Manage Jenkins →
  Nodes → docker-host into `.env`, `docker compose up -d jenkins-agent`.
  Until then, pushes queue no CI; the local lint gate is the only check.
  **Correction (2026-09-11):** `~/Documents/gh-runner/` does **not** exist on
  luna any more (no directory under `~`, no `JENKINS_AGENT_SECRET` anywhere in
  `~/Documents`, `~/.config`, `~/Projects`, no runner containers beyond the
  labs' own) — the stack lives on whichever host holds the docker socket for
  that agent. The controller itself answers (`curl -o /dev/null -w '%{http_code}'
  http://10.10.10.62:8080/` → 403, i.e. up and unauthenticated). So the fix is
  three steps on that host, none of which this repo can do for itself: fresh
  secret from the Jenkins UI → `.env` → `docker compose up -d jenkins-agent`.
- The repo's `Jenkinsfile` is a faithful port of the old lint workflow
  (agent label `docker`; `Dockerfile.agent` already ships shellcheck).

## Where validation stands

Validation happens in `~/Work/t1nk33r-lab-cachy` (branch `cachyos-guest`,
`LAB_DISTRO=cachyos`, CachyOS 260809 minimal, Limine, btrfs + snapper,
systemd initramfs).

- **Limine, no LUKS** (2026-09-07): the wrapper ran end to end on the guest,
  which rebooted through the transformed HOOKS into Omarchy's SDDM greeter
  with `ID=cachyos` intact; the profile import ran online (packages + mise
  for real) with a screenshot of the migrated Quickshell bar.
- **Limine + LUKS2** (2026-09-08): the same guest's root was converted in
  place from the live ISO (`./lab rescue`, `cryptsetup reencrypt`,
  `sd-encrypt` + `rd.luks.uuid=`). The wrapper's transformed HOOKS unlocked
  it on first boot; a re-apply reported `LUKS detected`, passed every
  assertion and rebooted into the greeter. The conversion also exposed a
  keyserver abort, now fixed (idempotent key import + fallback keyservers).
- **GRUB** (2026-09-07, non-Limine path): `--verify-only` after reboot
  reported 18 PASS, 0 FAIL; bootloader detection was exercised with the ESP
  unreadable and never mistook the `limine` package for the bootloader.
- **systemd-boot** (2026-09-11, `~/Work/t1nk33r-lab-cachyos-sdboot`): a copy
  of the GRUB lab converted in place (`bootctl install`, a loader entry built
  from `/proc/cmdline`, `efibootmgr -o`; it boots with `BootCurrent` = "Linux
  Boot Manager"). Detection answers `Bootloader: systemd-boot (bootctl
  LoaderInfo: systemd-boot 261.2-1-arch)` with `LUKS detected: true (cmdline
  unlock style: systemd)` and `/usr/bin/mkinitcpio -P`. It is a *conversion*,
  not an installer-chosen systemd-boot system: CachyOS's Limine packages were
  already present, which is the `cachyos-sdboot-luks` fixture's shape. The
  runs exposed four defects, all fixed and re-verified here on 2026-09-11:
  the ISO closure was missing `xdg-user-dirs` and `mise` (plan 037) and
  `chromium` (plan 039 — user seeding sets it as the default browser);
  snapper's stage is not idempotent when `/.snapshots` exists without
  `/etc/snapper/configs/root`, apply-system's own log was invisible to this
  script's failure diagnosis, and `limine-snapper-sync` left Limine artefacts
  on `/boot` that this script's own assertion then failed on (plan 040).
  Final state: a full run exits 0 with **19 PASS / 0 FAIL**, and so does
  `--verify-only` after a real reboot, with `rd.luks.uuid=` in the cmdline.
- **Limine + LUKS2, re-run against current HEAD** (2026-09-11, the v4 guest):
  gate 1's "the plan-017 fixes have not been re-run on a guest" is now closed,
  and the re-run found two more defects, both fixed: the closure shipped
  `[extra]`'s `mise`, which **conflicts** with `[omarchy]`'s `mise-bin` that
  Omarchy installs (plan 042), and `/etc/default/limine` assigning
  `KERNEL_CMDLINE[default]` silently replaced Omarchy's appended arguments, so
  the regenerated entries lost `initramfs_async=0` and the assertion suite
  failed the install (plan 041). The wrapper now appends exactly Omarchy's
  arguments to the assignment (backed up, idempotent). Evidence: a full run
  exits 0 with **19 PASS / 0 FAIL** — including
  *"/etc/default/limine carries the ENABLE_UKI/BOOT_ORDER/TARGET_OS_NAME
  overrides on a Limine host"* and *"the generated Limine entries keep
  omarchy-settings' initramfs_async=0 on a LUKS host"* — the entry's cmdline ends
  `… splash loglevel=0 systemd.show_status=false rd.udev.log_level=0
  vt.global_cursor_default=0 initramfs_async=0`, the boot's LUKS prompt is the
  themed Omarchy/Plymouth one (`run/shots/limine-luks-themed.png`, not the raw
  text prompt the regression produced), and `--verify-only` after that reboot is
  **19 PASS / 0 FAIL**.
- **Fresh install from the pristine golden** (2026-09-11, new lab
  `~/Work/t1nk33r-lab-cachy-omarchy`): the first install with every fix from
  plans 037–042 present, on a brand-new disk from the ISO bootstrap (Limine, no
  LUKS), `--autologin`. One run: `wrapper-exit=0`, **19 PASS / 0 FAIL**, and
  after a reboot the desktop comes up logged in with a clean panel.
  It exposed a *systematic* gap the earlier gates could not: the wrapper
  installed Omarchy's engine plus a hand-maintained closure, not Omarchy's
  stock application set — **104 of the 147** entries in
  `/usr/share/omarchy/install/omarchy-base.packages` were missing, and the
  panel reported it itself (`App failure: Command not found: "udiskie"`;
  `foot`, `grim`, `fzf`, `bat`, `eza`, `evince` were absent too). Plan 043
  makes the wrapper install that upstream list (provider-aware, skipping what
  no repo provides, with a one-shot `--overwrite` retry for files an earlier
  setup wrote unowned). After the fix: 0 unsatisfied entries.
  The lab is for human testing: ssh on the container's loopback port 2225 and a
  passwordless VNC console on 127.0.0.1:5905, which `~/Work/novnc/serve.sh`
  serves to a browser on 127.0.0.1:6080 (no root needed; `websockify` is a
  user-level uv tool).
- **Gate leftovers cleared in labs** (2026-09-11, later the same day): a kernel
  *package* transaction on the systemd-boot guest rebuilt the initramfs through
  the PATH-pinned override — libalpm's `--debug` names the hook file it parses
  and the two same-named hooks it skips, the initramfs mtime moved (20:19:38 →
  22:10:40), and the `check_no_limine_artifacts` glob stayed empty (gate 1);
  `--skip-user-configs` on a fresh GRUB guest skipped exactly the four named
  steps, left `$HOME` with no `.config` at all, put its transcript in `/tmp`,
  and still finished 19 PASS / 0 FAIL with the GPU session env printed rather
  than written (gate 1); a real `omarchy-settings` 4.0.2-1 → 4.0.3-1 upgrade ran
  the package's destructive etc-overrides scriptlet and
  `zz-cachyos-preserve-etc.hook` in the same transaction, while the control run
  with the hook made unreachable left `ID=omarchy` and Omarchy's nsswitch — the
  hook is load-bearing (gate 4); the picker's two untested paths are covered by
  mutation-checked cases (gate 5, `ea936fc`); and the drift guard, which could
  never fire on the run that introduces an off-baseline release, now re-checks
  after the package step and warns exactly once on both paths (`3875490`). Three
  README claims were corrected against the same evidence: the ufw mechanism on
  omarchy 4.0.3 (the live firewall is deliberately *not* touched; the wrapper's
  pre-allowance is still what makes the post-reboot firewall survive ssh), the
  snapper assertion being vacuous without a pre-install backup, and the drift
  baseline's reach.
- **Profile migration hardened** (2026-09-11, plan 044). The import was validated
  against the real luna bundle in a lab guest and the run exposed a blocking
  bug: `omacachy-profile-import.sh` aborted under `set -e`/`pipefail` when
  `/run/user/$UID/hypr` did not exist — exactly the station case of importing
  over ssh before logging in — so `packages`/`mise`/`services`/`verify` never
  ran. Fixed, together with the six package failures the run surfaced:
  `jack2` vs `pipewire-jack` and `mise-bin` vs `mise` became provider/installed
  conflict rules (the latter had demoted the 163-package batch into 163 serial
  transactions), `chaotic-*` is now skipped by the source repo the export
  records per package, a stale DB gets a refresh-and-retry, the Yaru file
  conflict gets the same one-shot `--overwrite` retry the wrapper uses, and a
  partial package stage now FAILS the run instead of printing `PARTIAL` and
  exiting 0. Proven in the guest with a freshly exported bundle: one
  uninterrupted run, every stage executed, doctor `0 failed` with the three
  remaining packages as *printed policy skips*, and its hypr/IPC checks
  correctly reported as SKIP (no live session), not as passes.
  `tests/run.sh` gained a `packages` section (31 assertions) and a `probe`
  section; the suite is now 303 passed / 0 failed.
- **`bin/debloat-quattro.sh`, driven interactively** (2026-09-11, the Omarchy 4
  guest): the picker ran on the desktop — one package removed through
  `omarchy-pkg-drop` (pacman transaction + snapper snapshots), one web app
  through the webapp helper, one agent CLI stub through the stub binder.
  Submitting a category empty exposed the bug plan 038 fixes: `gum choose
  --no-limit` prints one empty line, the empty-string element reached the
  removal phase, upstream refused it, and `set -e` skipped every later
  removal. Re-run after the fix: the selected stub is removed, no refusal, and
  the closing restore note prints.
- **Fixture matrix** (`tests/run.sh`): the HOOKS merge for both initramfs
  flavours and its refusal path, a dry run against four sysroot fixtures,
  and a dry-run purity check with failing command stubs.
- **Real GPUs**: `nvidia.sh` is dry-run only (no NVIDIA hardware in the lab);
  `amd-rocm.sh` ran for real on the dev machine (plan 036).

## Release gates (the honest "not done" list)

1. **Closed 2026-09-11.** The plan-017 fixes were re-run on the systemd-boot
   guest and on the Limine guest: the ISO package closure (now including
   `xdg-user-dirs`, `mise-bin` and `chromium`), the ufw ssh allowance and the
   `/etc/environment` `OMARCHY_PATH` write all assert PASS in the same run, and
   the shadow `HookDir` override was exercised inside a live pacman
   transaction. The two items that were still fixture-only were then cleared in
   labs the same day: an initramfs rebuild triggered by a **kernel package
   transaction** (libalpm `--debug` shows it parsing
   `/etc/pacman.d/hooks-omacachy/90-mkinitcpio-install.hook` and *skipping* both
   same-named hooks, the initramfs mtime moved, no Limine artefacts), and
   `--skip-user-configs` on a **fresh** GRUB guest (four named steps skipped,
   `$HOME` untouched, transcript in `/tmp`, still 19 PASS / 0 FAIL).
2. **systemd-boot CachyOS machine** — run for real on 2026-09-11 on a guest
   converted from GRUB: detection, the hook policy, the initramfs rebuild, the
   post-install assertion suite (19 PASS / 0 FAIL) and `--verify-only` after a
   reboot all pass. Not yet exercised: an *installer*-chosen systemd-boot (this
   was a conversion), and a systemd-boot machine without CachyOS's Limine
   packages installed.
3. **Real GPUs** — `amd-rocm.sh` ran for real on the dev machine 2026-09-11
   (plan 036: four packages plus the env file, `vainfo`/`rocm-smi`/`vulkaninfo`
   on the card, graphics stack untouched). **`nvidia.sh` is out of scope for
   this setup** and stays code-reviewed-only: there is no NVIDIA hardware on
   luna, and the station is AMD too (the profile bundle exported 2026-09-11
   records `GPU vendor | amd`). If an NVIDIA machine ever appears, that gate
   half is one `bin/nvidia.sh` run plus the browser-decode notes in README §5.1.
4. **Closed 2026-09-11.** A real `omarchy-settings` **upgrade** transaction
   (4.0.2-1 → 4.0.3-1, fired by the wrapper's own `pacman -Syu` on the Limine
   guest) ran the package's deliberately destructive `_etc_overrides_apply()`
   scriptlet — it `rm -f`s and replaces `/etc/os-release` and
   `/etc/nsswitch.conf` on every install/upgrade — and
   `/etc/pacman.d/hooks/zz-cachyos-preserve-etc.hook` in the same transaction,
   so `ID=cachyos` and CachyOS's nsswitch survived and the suite passed 19/0.
   The control run with the hook deliberately unreachable leaves `ID=omarchy`,
   `PRETTY_NAME="Omarchy"` and Omarchy's nsswitch: the hook is load-bearing, not
   cosmetic.
5. **Closed 2026-09-11.** The interactive run happened (see §Where validation
   stands), the empty-category bug it exposed is fixed (plan 038), and the two
   paths still listed as unexercised are now covered by tests (commit
   `ea936fc`): every category submitted empty (the "nothing selected" exit) and
   the removal-loop ownership guard refusing an executable Omarchy did not
   write. Both cases are mutation-checked — removing the early exit or the
   re-check in a copy of the script fails exactly those assertions, so they are
   load-bearing rather than decorative.
6. **CI is GitHub Actions now** (2026-09-11): `.github/workflows/lint.yml`,
   `name: omacachy`, runs the repo's own gate (`bash -n` over every entry point
   and helper, `shellcheck --severity=warning -x`, then `tests/run.sh`) on
   pushes to `main`/`omacachy` and on pull requests, on `ubuntu-latest`. The
   `Jenkinsfile` is deleted and the Jenkins agent + its unrecoverable secret are
   retired with it — that item is closed by removal, not by repair. The runner
   stack's entry for this repository is still named `runner-omarchy`; rename it
   to `omacachy` there if the self-hosted path is ever wanted back (the workflow
   would need `runs-on: [self-hosted, linux, docker]`). First runs exposed that
   the suite was only *apparently* hermetic, and fixing that closed three real
   gaps: the fixture harness had no `pacman`, so a runner without it failed 140
   matrix assertions at the wrapper's preflight (`4b367fb`); `.gitignore`'s
   unanchored `omarchy/` rule was hiding two fixture files under
   `tests/fixtures/*/usr/share/omarchy/`, which made `base_packages` and
   `snapper_reapply` decide differently on a fresh checkout than on the
   maintainer's host (`2849c80`); and the profile and picker sections called the
   host `pacman` directly, so manifest/rollback/probe died on "missing required
   command(s): pacman" and the picker enumerated nothing (`7c8ca91`).
   The suite now passes **304 / 0** in an `ubuntu:24.04` container with no Arch
   tooling, again under `--network none` with a tree rebuilt from `git ls-files`
   (proving it needs nothing untracked and no network), and **304 / 0** on the
   Arch host. **CI is green on push** (run `34643893131`, 51 s).
7. Backlog: opt-in debloat prompt inside the wrapper;
   `--restore-host-specific`; lab hardening (fixed 90 s wait, typed launch
   line) and merging the lab's `cachyos-guest` branch.
8. **Secure Boot — validated in a lab 2026-09-11; no longer hardware-blocked.**
   The runner's `edk2-ovmf` ships `OVMF_CODE.secboot.4m.fd`, so a lab copy boots
   into pristine UEFI Setup Mode with a one-line firmware swap (the VARS
   template is shared; `smm=on` + `pflash01.secure=on` are optional hardening).
   With keys enrolled (`sbctl create-keys`, `enroll-keys --microsoft`), Secure
   Boot enforcing and the EFI loaders signed, a full wrapper run finishes
   `wrapper-exit=0` with **19 PASS / 0 FAIL / 0 SKIP**, reboots with
   `Secure Boot: enabled (user)` and stays green. Two traps recorded: (a)
   Omarchy's `limine-install` overwrites the *removable-media fallback* loader
   `/boot/EFI/BOOT/BOOTX64.EFI` with the unsigned packaged binary on every
   seeding run — the wrapper now re-signs it when `sbctl status` reports Secure
   Boot enabled (`226fa38`, after the lab verification caught the gate regex
   being defeated by sbctl's `Secure Boot:\t✓ Enabled` check-mark glyph); (b)
   never sign the `/boot/<machine-id>/**/vmlinuz` copies on a non-UKI Limine
   host — Limine pins their BLAKE2b hash in `limine.conf` and signing them ends
   in `PANIC: Blake2b hash … does not match`. Not yet tested: an SB machine
   whose bootloader was chosen by an installer (this was Limine from the
   golden), and UKI-mode Secure Boot.

## Fast orientation for an agent

Read in this order: this file → `plans/README.md` (status + discoveries
index) → the specific plan file for whatever you're touching (016 = current
wrapper behaviour, the audit of 015 and the test seam; 017 = the corrections
from the first real CachyOS run; 018 = profile migration — bundle format,
secret/package policy, the adopt/reject table for the two candidate
repositories; 015 = the 4.0.2 evidence trail, with two mechanisms since
corrected by 016; 012 = original wrapper design; 011 = v4 strategy
evidence; 007/008 = GPU evidence trail).
Before changing `bin/install-omarchy-quattro.sh`, run `tests/run.sh` and
re-run it after: the fixture matrix is what catches a branch flipping.
Trust the plan files' quoted evidence over memory; the best upstream source
is an *installed* Omarchy (`pacman -Ql omarchy omarchy-settings`,
`/usr/share/omarchy/**`, `/var/lib/pacman/local/*/install`); re-probe
`basecamp/omarchy` via git otherwise — it moves fast and the CDN lies.
