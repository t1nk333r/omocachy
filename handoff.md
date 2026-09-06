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
| Omarchy 4 "Quattro" package wrapper | `bin/install-omarchy-quattro.sh` | Reconciled against installed 4.0.2 (plan 015), dry-run-verified, **not yet run for real on CachyOS** |
| v4 per-item debloat picker | `bin/debloat-quattro.sh` | Built, mock-verified, needs real-v4 TUI run |
| GPU dispatch | `bin/gpu-detect.sh` → `gpu-setup.sh` → `nvidia.sh`/`amd-rocm.sh` | Working; NVIDIA regex covers 580xx/470xx; AMD is VA-API-only; session env goes to `~/.config/uwsm/env.d/50-omocachy-gpu`, never `~/.config/uwsm/env` |

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
- **Lint gate**: `bash -n bin/*.sh` plus `shellcheck --severity=warning
  bin/*.sh` (shellcheck 0.11 locally; in CI via the `Jenkinsfile`). Run it
  before every push.
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

## Release gates (the honest "not done" list)

1. **Real CachyOS validation of the Quattro wrapper** — dry-run and the
   fixture matrix (`tests/run.sh`, plan 016) prove the command plan, the
   rendered files and the *branch selection* on CachyOS-shaped input. They do
   not prove the resulting system boots. Wanted: one GRUB+LUKS VM, one
   Limine+LUKS VM (systemd initramfs, `rd.luks.uuid=`), one systemd-boot VM,
   fresh CachyOS each; run once with `--skip-user-configs` (dotfiles-managed
   home) and once without. Specifically confirm: the transformed
   `zz-cachyos-keep-hooks.conf` boots; the extra `HookDir`
   (`/etc/pacman.d/hooks-omocachy/`) really shadows
   `limine-mkinitcpio-hook`'s `90-mkinitcpio-install.hook` in a live
   transaction, and an initramfs rebuild still fires on a kernel upgrade;
   `limine-snapper-sync` accepts `TARGET_OS_NAME="CachyOS"`;
   `/etc/os-release` stays `ID=cachyos` across an `omarchy-settings` upgrade
   (preserve hook); SDDM shows the remembered user; `--verify-only` is green
   after the first `omarchy update`. The dev machine (Omarchy ISO install,
   Limine+LUKS+AMD, udev initramfs) can only exercise the re-apply path.
2. **Real interactive run of `bin/debloat-quattro.sh` on a v4 machine**
   (same VM gate) — enumeration/dry-run are mock-verified only.
3. **Jenkins agent secret** (above) — then confirm a green build on push.
4. Backlog seeds, if wanted: opt-in debloat prompt inside the Quattro
   wrapper (deliberately deferred until gate 1 passes).

## Fast orientation for an agent

Read in this order: this file → `plans/README.md` (status + discoveries
index) → the specific plan file for whatever you're touching (016 = current
wrapper behaviour, the audit of 015 and the test seam; 015 = the 4.0.2
evidence trail, with two mechanisms since corrected by 016; 012 = original
wrapper design; 011 = v4 strategy evidence; 007/008 = GPU evidence trail).
Before changing `bin/install-omarchy-quattro.sh`, run `tests/run.sh` and
re-run it after: the fixture matrix is what catches a branch flipping.
Trust the plan files' quoted evidence over memory; the best upstream source
is an *installed* Omarchy (`pacman -Ql omarchy omarchy-settings`,
`/usr/share/omarchy/**`, `/var/lib/pacman/local/*/install`); re-probe
`basecamp/omarchy` via git otherwise — it moves fast and the CDN lies.
