# Plan 036: Make amd-rocm.sh's chwd step optional so the AMD path can be exercised off CachyOS

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `70bbade`, 2026-09-11
- **Executed**: 2026-09-11, in the same commit as this file (reviewer pass).
  The real-device half of release gate 3 followed the same evening:
  `bin/amd-rocm.sh` ran for real on the dev machine (AMD RX 7900 XTX) —
  detection, the chwd-skip warning, the package transaction
  (`rocm-language-runtime rocm-cmake rocm-hip-runtime libva-utils`; four
  fresh installs, no upgrades) and the session-env write all succeeded;
  `vainfo` reports Mesa radeonsi on the GPU, `vulkaninfo` enumerates it via
  RADV, `rocm-smi` reads it, and Mesa/RADV/firmware were untouched.

## Why this matters

`handoff.md`'s release gate 3 says the dev machine (AMD) can run `amd-rocm.sh`
for real — the last unexercised GPU path. On this machine it cannot: the
script's first privileged step is `run_root chwd -i amd`, and `chwd` is
CachyOS-only and absent here (not packaged in core/extra/multilib/omarchy/
chaotic-aur). The run aborts there, before installing anything. The same
abort bites the wrapper on any host it warns about-but-continues on: it gets
through the CachyOS check, applies, and then dies at the GPU step — skipping
snapper, bootloader reconciliation, the initramfs rebuild and the assertion
suite. The script is also documented as a standalone entry point (README §5,
and the doctor prints `run bin/gpu-setup.sh …`), so a hard dependency on a
distro-specific binary is the same defect class plan 033 fixed for the no-GPU
guard: a branch the code cannot reach.

## What changed

- `bin/amd-rocm.sh`: the driver-profile step is now

  ```bash
  if have chwd; then
      info "Installing AMD AMDGPU driver profile..."
      run_root chwd -i amd
  else
      warn "chwd (CachyOS's hardware detection) is not installed; skipping the
  AMDGPU driver-profile step. Install your distribution's AMDGPU/ROCm packages
  by hand if needed."
  fi
  ```

  (wrapped, matching the file's style). On CachyOS the behaviour is unchanged
  — `chwd` exists, the step runs as before.
- `tests/run.sh` (`gpu` section): two new cases pin both branches on any host,
  using an exclusive `PATH` whose shim holds `bash`, `dirname`, `grep`, `head`,
  `sed` and a stub `lspci` reporting an AMD device: without `chwd` the run
  completes, prints the warning and plans no `chwd` command; with a stub
  `chwd` prepended it plans `DRYRUN: sudo chwd -i amd`.
- `README.md` §5: the AMD bullet now says `chwd` "where CachyOS's hardware
  detection is available", and that elsewhere the step is skipped with a
  warning.

## Verification (done in the same commit)

- `tests/run.sh gpu` → `20 passed, 0 failed` (5 new assertions);
  `tests/run.sh` → `250 passed, 0 failed`; lint gate exit 0.
- On this host (no `chwd`): `bin/amd-rocm.sh --dry-run` now prints the warning
  and continues through the package and session-env steps instead of planning
  `sudo chwd`.
- The real run (packages + `~/.config/uwsm/env.d/50-omocachy-gpu`) is the
  remaining half of release gate 3 and needs the operator's sudo; the handoff
  wording is updated once it has run.

## Considered and rejected

- **Leaving the script CachyOS-only**: rejected — the abort costs the wrapper
  its post-apply reconciliation on non-CachyOS hosts and makes the documented
  standalone use impossible; the guarded form costs nothing on CachyOS.
- **Also defaulting the ROCm package set for non-CachyOS hosts**: out of
  scope; the script installs the same Arch package names, which is correct on
  Arch and CachyOS alike.
