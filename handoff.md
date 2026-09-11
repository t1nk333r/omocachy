# Handoff — omocachy

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
| Profile migration (export → import → doctor) | `bin/omocachy-profile-export.sh`, `bin/omocachy-profile-import.sh`, `bin/omocachy-doctor.sh` | Plan 018. Exercised end to end for real in the Omarchy lab VM (export, import onto a pristine guest, screenshot of the migrated desktop, `./lab test` green, rollback, re-import); the `packages` and `mise` stages ran online against a real CachyOS guest |
| Shared helpers | `bin/lib/common.sh`, `bin/lib/profile.sh`, `share/profile-paths.conf` | `common.sh` is the dry-run contract shared by the profile scripts; `profile.sh` owns bundle schema 1 and the exclude/secret/package policies |
| GPU dispatch | `bin/gpu-detect.sh` → `gpu-setup.sh` → `nvidia.sh`/`amd-rocm.sh` | Working; NVIDIA probes the PCI id for the generation and warns on the one broken combination (open module, pre-Turing), installs `libva-nvidia-driver`, and writes a `modeset=1` drop-in only when nothing else sets one; AMD is VA-API-only; session env goes to `~/.config/uwsm/env.d/50-omocachy-gpu`, never `~/.config/uwsm/env`; all honour `--dry-run` |

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
   (wrapper/tests on `main`, profile/LUKS on `omocachy`) were consolidated
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
- **Fixture matrix** (`tests/run.sh`): the HOOKS merge for both initramfs
  flavours and its refusal path, a dry run against four sysroot fixtures,
  and a dry-run purity check with failing command stubs.
- **systemd-boot** and **real GPUs**: fixtures / dry-run only (the guest has
  no GPU). The dev machine (AMD) can exercise `amd-rocm.sh` for real.

## Release gates (the honest "not done" list)

1. **The plan-017 fixes have not been re-run on a guest** — they landed after
   the last real run (2026-09-07). The next real CachyOS run re-tests the ISO
   package closure, the ufw ssh allowance and the `/etc/environment`
   `OMARCHY_PATH` write together. Still fixture-only: a non-Limine `HookDir`
   override inside a live pacman transaction, an initramfs rebuild on a
   kernel upgrade, `limine-snapper-sync` accepting `TARGET_OS_NAME="CachyOS"`,
   and a `--skip-user-configs` run on a fresh guest.
2. **systemd-boot CachyOS install** — fixtures only; GRUB and Limine (with
   and without LUKS2) have run for real.
3. **Real GPUs** — `nvidia.sh`/`amd-rocm.sh` are dry-run only; the dev
   machine (AMD) can run `amd-rocm.sh` for real.
4. **`omarchy-settings` upgrade through the preserve hook** — installed and
   the first-install restore verified; no upgrade transaction has fired the
   hook yet.
5. **Real interactive run of `bin/debloat-quattro.sh`** on the CachyOS
   guest — enumeration/dry-run are mock-verified only.
6. **Jenkins agent secret** (above) — then confirm a green build on push.
7. Backlog: opt-in debloat prompt inside the wrapper;
   `--restore-host-specific`; lab hardening (fixed 90 s wait, typed launch
   line) and merging the lab's `cachyos-guest` branch.

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
