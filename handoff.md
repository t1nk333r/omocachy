# Handoff — omocachy

Orientation for whoever (human or agent) picks this project up next.
Updated 2026-09-06. User-facing docs live in
`README.md`; the full engineering record lives in `plans/` — this file is
the map between them.

## What this repo is now

A standalone project (fork of `mroboff/omarchy-on-cachyos`, **not**
PR-bound — clone URLs point at `d7eeem/omocachy`; `FUNDING.yml` deliberately still
credits the original author). It installs Omarchy 4 on CachyOS with a
per-item debloater:

| Component | Script | State |
|---|---|---|
| Omarchy 4 "Quattro" package wrapper | `bin/install-omarchy-quattro.sh` | Reconciled against installed 4.0.2 (plan 015); **ran end to end on a real CachyOS 260809 minimal/Limine guest, rebooted into Omarchy** (plan 016). LUKS, GRUB, real GPUs still open |
| v4 per-item debloat picker | `bin/debloat-quattro.sh` | Built, mock-verified, needs real-v4 TUI run |
| Profile migration (export → import → doctor) | `bin/omocachy-profile-export.sh`, `bin/omocachy-profile-import.sh`, `bin/omocachy-doctor.sh` | Plan 016. Exercised end-to-end for real in the lab VM (export, import onto a pristine guest, screenshot, `./lab test` green, rollback, re-import). `packages`/`mise` stages verified only in classification/offline paths |
| Shared helpers | `bin/lib/common.sh`, `bin/lib/profile.sh`, `share/profile-paths.conf` | `common.sh` is the installer's own dry-run contract, extracted verbatim (dry-run output byte-identical); `profile.sh` owns bundle schema 1 and the exclude/secret/package policies |
| GPU dispatch | `bin/gpu-detect.sh` → `gpu-setup.sh` → `nvidia.sh`/`amd-rocm.sh` | Working; NVIDIA regex covers 580xx/470xx and now reports the GPU generation, installs `nvidia-vaapi-driver` and writes a `modeset=1` drop-in when nothing else does; AMD is VA-API-only; session env goes to `~/.config/uwsm/env.d/50-omocachy-gpu`, never `~/.config/uwsm/env`; both accept `--dry-run` |

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

## Working conventions (keep these)

- **Follow Omarchy's native interfaces**: the Quattro picker derives its
  candidate lists and removal behavior from the installed Omarchy scripts,
  with MIT attribution in its header.
- **Plan → executor → review**: plans in `plans/NNN-*.md` are self-contained
  for a zero-context executor, stamped with the commit they were written
  against (drift-check first). Executors run in isolated git worktrees; the
  reviewer re-runs done criteria, reads the whole diff, then fast-forwards
  main. Never merge a worktree branch while your shell's cwd is inside it.
- **Lint gate**: `bash -n bin/*.sh bin/lib/*.sh` plus `shellcheck
  --severity=warning -x bin/*.sh bin/lib/*.sh` (`-x` so the sourced
  `bin/lib/` helpers are followed; shellcheck 0.11 locally; in CI via the
  `Jenkinsfile`). Run it before every push.
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

Plan 016 (2026-09-07) closed the two big gates on a real CachyOS guest —
`~/Work/t1nk33r-lab-cachy` (branch `cachyos-guest`, `LAB_DISTRO=cachyos`,
CachyOS 260809 minimal/Limine/btrfs+snapper/no LUKS): the Quattro wrapper
ran end to end (10/10 assertions), the guest rebooted through the
transformed HOOKS into Omarchy's SDDM greeter with `ID=cachyos` intact, and
the profile import ran online (packages + mise for real) with a screenshot
of the migrated Quickshell bar. Two real-host bugs were found and fixed on
the way: apply-system needs `omarchy-base.packages` installed first, and
the user seeding needs Omarchy's `env-bootstrap` sourced (`OMARCHY_PATH`).
Details and evidence: the plan file.

## Release gates (the honest "not done" list)

1. **GRUB / systemd-boot CachyOS installs** — the non-Limine hook
   overrides are still dry-run/harness only. (LUKS+Limine is done: the
   guest's root was converted in place with `./lab rescue`, the wrapper
   re-applied 10/10 and it boots through `rd.luks.uuid=`; plan 016.)
2. **Real GPUs** — the VM has none; `nvidia.sh`/`amd-rocm.sh` were only
   dry-run. The dev machine (AMD) can exercise `amd-rocm.sh` for real.
3. **`omarchy-settings` upgrade through the preserve hook** — the hook is
   installed and the first-install restore verified; an actual upgrade
   transaction has not fired it yet.
4. **Real interactive run of `bin/debloat-quattro.sh`** on the CachyOS guest
   — enumeration/dry-run are mock-verified only.
5. **Jenkins agent secret** (above) — then confirm a green build on push.
6. Backlog: opt-in debloat prompt inside the wrapper; harden the lab's
   CachyOS driver (fixed 90 s wait, typed launch line) and merge
   `cachyos-guest` into the main lab checkout.

## Fast orientation for an agent

Read in this order: this file → `plans/README.md` (status + discoveries
index) → the specific plan file for whatever you're touching (016 = profile
migration: bundle format, secret/package policy, the adopt/reject table for
the two candidate repositories; 015 = current wrapper behaviour with 4.0.2
evidence, 012 = original wrapper design, 011 = v4 strategy evidence,
007/008 = GPU evidence trail). Trust the plan files'
quoted evidence over memory; the best upstream source is an *installed*
Omarchy (`pacman -Ql omarchy omarchy-settings`, `/usr/share/omarchy/**`,
`/var/lib/pacman/local/*/install`); re-probe `basecamp/omarchy` via git
otherwise — it moves fast and the CDN lies.
