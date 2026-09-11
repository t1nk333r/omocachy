# Plan 019: Fix the NVIDIA VA-API package name and the two misses in nvidia.sh

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If any
> STOP condition occurs, stop and report — do not improvise. When done, update
> the status row for this plan in `plans/README.md` (or leave it to the
> reviewer if they said they maintain the index).
>
> **Drift check (run first)**: `git diff --stat e80b564..HEAD -- bin/nvidia.sh handoff.md plans/018-omarchy-profile-migration.md`
> If any of those files changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `e80b564`, 2026-09-11
- **Executed**: 2026-09-11 (landed at `76c94a0`); the Done criterion's global grep and Step 2's match count were corrected in `e0d1c3f` — this plan file quotes the wrong package name by design.

## Why this matters

`bin/nvidia.sh` installs a package that does not exist. On Arch/CachyOS the
NVIDIA VA-API backend is `libva-nvidia-driver` (extra, 0.0.18-1); the name in
the script (`nvidia-vaapi-driver`) names the *upstream project*, not a package.
`bin/nvidia.sh` runs under `set -euo pipefail`, so pacman's exit 1 aborts the
script before it writes the `nvidia_drm modeset` drop-in and the session env
file — and when the wrapper drives it (`bin/install-omarchy-quattro.sh:1599`
calls `gpu-setup.sh` under `set -Eeuo pipefail`), the whole install stops at
the GPU step: Snapper/bootloader reconciliation, the initramfs rebuild and the
assertion suite never run. Every NVIDIA machine hits this.

## Current state

- `bin/nvidia.sh` — vendor installer for NVIDIA. `:2` is `set -euo pipefail`;
  `:19-20` parse `--dry-run`; `:22-26` skip cleanly when no NVIDIA GPU is
  present (correct shape, keep it); `:71` detects an installed driver; `:74`
  warns about an open module on a pre-Turing card; `:96` installs packages.
- The exact current lines:
  - `bin/nvidia.sh:71`:
    ```bash
    NVIDIA_DRIVER=$(pacman -Qq | grep -E '^nvidia(-open)?(-[0-9]+xx)?-(dkms|utils)$' | head -n1 || true)
    ```
  - `bin/nvidia.sh:74`:
    ```bash
    if ! $SUPPORTS_OPEN_GSP && pacman -Qq | grep -q '^nvidia-open'; then
        warn "an open kernel module package is installed but this GPU ($ARCH_NAME) has no GSP firmware support; it will not initialise. Switch to the proprietary branch (e.g. 'sudo chwd -i nvidia')."
    ```
  - `bin/nvidia.sh:96`:
    ```bash
    run_root pacman -S --needed --noconfirm libva-utils nvidia-vaapi-driver
    ```
- Facts to rely on (verified 2026-09-11 on the dev host):
  - `pacman -Si libva-nvidia-driver` → `Repository: extra`, `Version: 0.0.18-1`.
  - `pacman -Sp nvidia-vaapi-driver` → `error: target not found`.
  - Upstream Omarchy's own installer uses the correct name:
    `/usr/share/omarchy/install/hardware/nvidia.sh:7` installs
    `nvidia-open-dkms nvidia-utils lib32-nvidia-utils libva-nvidia-driver`.
  - `plans/007-chwd-invocation-audit.md` ("Investigation results" 4, chwd
    1.24.1 profiles.toml) records the real chwd profiles: `nvidia-open-dkms`,
    `nvidia-dkms-580xx`, `nvidia-dkms-470xx` (+ `.prime` variants), `nouveau`.
    There is no plain `nvidia` profile, so `chwd -i nvidia` cannot succeed.
  - The driver comment at `bin/nvidia.sh:61-69` already says the kernel
    modules come from a per-kernel package (`linux-cachyos-nvidia-open`) *or*
    a raw dkms package — the open-module check must match both forms.
- Wrong name also appears in `handoff.md` (GPU dispatch row: "installs
  `nvidia-vaapi-driver`") and `plans/018-omarchy-profile-migration.md:35`.
- Repo conventions: `run_root` is the privileged wrapper (`bin/lib/common.sh`);
  dry-run prints instead of executing; shellcheck at warning severity is the
  local gate.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Existence of the real package | `pacman -Si libva-nvidia-driver` | prints a Repository/Version block |
| Lint | `bash -n bin/*.sh bin/lib/*.sh tests/run.sh && shellcheck --severity=warning -x bin/*.sh bin/lib/*.sh tests/run.sh` | exit 0, no findings |
| Fixture suite | `tests/run.sh` | ends `N passed, 0 failed` |

## Scope

**In scope** (only these files):
- `bin/nvidia.sh`
- `handoff.md` (the one GPU-row mention)
- `plans/018-omarchy-profile-migration.md` (the one table mention)

**Out of scope**:
- `bin/amd-rocm.sh`, `bin/gpu-setup.sh` — their robustness is plan 033.
- The wrapper's GPU dispatch call site — unchanged.
- `bin/lib/common.sh` — unchanged.

## Git workflow

- Branch: `advisor/019-nvidia-vaapi-package-name`
- One commit; message style matches this repo's imperative summaries, e.g.
  `Fix the NVIDIA VA-API package name; probe both open-module package forms`
  with a body naming the evidence (`pacman -Si` result, upstream file path).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Replace the package name

In `bin/nvidia.sh:96` change `nvidia-vaapi-driver` to `libva-nvidia-driver`.
Keep `libva-utils` (it provides `vainfo`, which the script's comment relies on).

**Verify**: `grep -rn 'nvidia-vaapi-driver' bin/ handoff.md plans/` → no matches in `bin/`; then fix the two doc mentions (Step 4).

### Step 2: Probe both open-module package forms

In `bin/nvidia.sh:74` replace the check with one that matches the per-kernel
form as well:

```bash
if ! $SUPPORTS_OPEN_GSP && pacman -Qq | grep -qE '^nvidia-open|^linux-.*-nvidia-open$'; then
```

(The comment at `:61-69` already documents both packaging forms; this makes the
check agree with it.)

**Verify**: `grep -n 'linux-.*-nvidia-open' bin/nvidia.sh` → two matches: the
new probe at `:74` and the pre-existing comment at `:66`.

### Step 3: Warn with a profile that exists

In the same warning, replace `(e.g. 'sudo chwd -i nvidia')` with the versioned
profile implied by the probe's own generation, keeping the hedge, e.g.:

```
Pascal -> 'sudo chwd -i nvidia-dkms-580xx', Maxwell -> 'sudo chwd -i nvidia-dkms-470xx'
```

Use the `ARCH_NAME`/generation values the script already computes (see the
comment at `:61-69`); do not invent profile names beyond the set recorded in
`plans/007-chwd-invocation-audit.md`.

**Verify**: `grep -n 'chwd -i' bin/nvidia.sh` → no plain `nvidia` profile.

### Step 4: Fix the two documentation mentions

- `handoff.md` — the GPU dispatch row: replace `nvidia-vaapi-driver` with
  `libva-nvidia-driver`.
- `plans/018-omarchy-profile-migration.md:35` — same replacement, and append
  `(corrected 2026-09-11: the package is libva-nvidia-driver)` so the record
  shows the correction rather than silently changing history.

**Verify**: `grep -rn 'nvidia-vaapi-driver' . --exclude-dir=.git` → no matches.

### Step 5: Lint and suite

**Verify**: `bash -n bin/*.sh bin/lib/*.sh tests/run.sh && shellcheck --severity=warning -x bin/*.sh bin/lib/*.sh tests/run.sh` → exit 0. Then `tests/run.sh` → `0 failed`.

## Test plan

- No new test file: this script is not executed by the suite (see plan 029,
  which adds coverage for the GPU scripts). The regression signal for this fix
  is the grep in Step 4 plus the fact that the package name is now the one
  `pacman -Si` resolves.
- If plan 029 has landed, add one line to its GPU section: assert that
  `bin/nvidia.sh` contains `libva-nvidia-driver` and does not contain
  `nvidia-vaapi-driver` (a text assertion is acceptable here because the
  package name is the contract with pacman).

## Done criteria

- [ ] `grep -rn 'nvidia-vaapi-driver' bin/ handoff.md README.md` returns
      nothing (this plan file quotes the wrong name by design)
- [ ] `grep -n 'libva-nvidia-driver' bin/nvidia.sh` returns the install line
- [ ] `grep -n 'linux-.*-nvidia-open' bin/nvidia.sh` returns the probe
- [ ] Lint gate exits 0; `tests/run.sh` ends `0 failed`
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- `pacman -Si libva-nvidia-driver` fails on the machine you are working on
  (different repo layout than the dev host) — report the output instead of
  guessing a name.
- `bin/nvidia.sh` no longer matches the excerpts above (drift).
- The fix appears to require touching the wrapper or `bin/lib/common.sh`.

## Maintenance notes

- A reviewer should confirm the install line still runs through `run_root`
  (dry-run contract) and that `libva-utils` stays installed alongside it.
- If CachyOS ever ships a differently named VA-API package, the changelog for
  `libva-nvidia-driver` is the place to notice; the `pacman -Si` check in this
  plan is the cheap re-verification.
- Deferred: an assertion in the wrapper's suite that `vainfo` resolves after a
  real install (needs real NVIDIA hardware).
