# Plan 033: Make the GPU scripts reject unknown flags and stop dying silently

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If any
> STOP condition occurs, stop and report — do not improvise. When done, update
> the status row for this plan in `plans/README.md` (or leave it to the
> reviewer).
>
> **Drift check (run first)**: `git diff --stat e80b564..HEAD -- bin/gpu-setup.sh bin/nvidia.sh bin/amd-rocm.sh bin/gpu-detect.sh`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plan 019 (nvidia.sh edits; land after it)
- **Category**: bug
- **Planned at**: commit `e80b564`, 2026-09-11

## Why this matters

`bin/gpu-setup.sh` and the two vendor scripts accept flags by testing only `$1`
and ignore everything else, so a mistyped `--dry-run` (or a flag in another
position) silently takes the real privileged path — `chwd -a`, `pacman -S` and
a write into `$HOME/.config/uwsm/env.d/`. `bin/gpu-setup.sh` also has no
`default:` branch, so a detector value it does not recognise exits 0 having
done nothing. And `bin/amd-rocm.sh:14` assigns `GPU_ID` from a pipeline under
`set -euo pipefail`; on a machine with no AMD GPU the pipeline fails and the
script exits 1 before its own "No AMD GPU found. Skipping." guard — a silent
no-output abort where a documented skip was intended. Every other entry point
in the repo validates its arguments and skips gracefully.

## Current state

- `bin/gpu-setup.sh:9-24`:
  ```bash
  GPU_TYPE=$(bash "$SCRIPT_DIR/gpu-detect.sh")

  case "$GPU_TYPE" in
  nvidia)
      echo "[*] NVIDIA GPU detected, running nvidia.sh..."
      bash "$SCRIPT_DIR/nvidia.sh" "$@"
      ;;
  amd)
      echo "[*] AMD GPU detected, running amd-rocm.sh..."
      bash "$SCRIPT_DIR/amd-rocm.sh" "$@"
      ;;
  none)
      echo "[*] No GPU detected, skipping GPU setup."
      exit 0
      ;;
  esac
  ```
  (No `default`, no flag validation; header comment says "Arguments (e.g.
  --dry-run) are forwarded to the vendor script.")
- `bin/nvidia.sh:19-20` and `bin/amd-rocm.sh:13-14`:
  ```bash
  DRY_RUN=false
  [[ ${1:-} == --dry-run ]] && DRY_RUN=true
  ```
- `bin/amd-rocm.sh:14` is the arithmetically similar pipeline:
  ```bash
  GPU_ID=$(lspci -nn -d 1002: | grep -E "VGA|3D" | head -n1 | sed -n 's/.*\[1002:\([0-9a-fA-F]\{4\}\)\].*/\1/p')
  ```
  `bin/nvidia.sh:22-25` shows the correct shape:
  ```bash
  if ! lspci -nn -d 10de: | grep -qE "VGA|3D"; then
      info "No NVIDIA GPU found. Skipping."
      exit 0
  fi
  ```
- `bin/gpu-detect.sh` (11 lines) prints exactly `nvidia`, `amd` or `none`:
  ```bash
  if lspci -nn -d 10de: | grep -qE "VGA|3D"; then
      echo "nvidia"
  elif lspci -nn -d 1002: | grep -qE "VGA|3D"; then
      echo "amd"
  else
      echo "none"
  fi
  ```

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `bash -n bin/*.sh bin/lib/*.sh tests/run.sh && shellcheck --severity=warning -x bin/*.sh bin/lib/*.sh tests/run.sh` | exit 0 |
| Fixture suite | `tests/run.sh` | `0 failed` |
| No-AMD skip | the PATH-shim command in Step 3 | `No AMD GPU found. Skipping.`, exit 0 |
| Unknown flag | `bash bin/amd-rocm.sh --bogus` | usage on stderr, exit 1 |

## Scope

**In scope**: `bin/nvidia.sh`, `bin/amd-rocm.sh`, `bin/gpu-setup.sh`,
`bin/gpu-detect.sh` (only if it needs a guard), `tests/run.sh` (cases; see
plan 029 for where).

**Out of scope**: the driver logic itself (plans 007/008 territory), the
wrapper's dispatch call site, `OMACACHY_SKIP_USER_CONFIGS` handling.

## Git workflow

- Branch: `advisor/033-gpu-script-robustness`
- Commit message, e.g.: `Validate GPU script flags; make the no-GPU guard reachable`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Strict flag parsing in both vendor scripts

Replace the two-line flag block in `bin/nvidia.sh` and `bin/amd-rocm.sh` with:

```bash
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h | --help)
        echo "Usage: $(basename "$0") [--dry-run]"
        exit 0
        ;;
    *)
        echo "Unknown argument: $arg" >&2
        echo "Usage: $(basename "$0") [--dry-run]" >&2
        exit 1
        ;;
    esac
done
```

Keep the surrounding style (4 spaces).

**Verify**: `bash bin/nvidia.sh --bogus` → usage, exit 1;
`bash bin/nvidia.sh --help` → usage, exit 0 (same for `amd-rocm.sh`).

### Step 2: Make the AMD guard reachable

In `bin/amd-rocm.sh`, append `|| true` to the `GPU_ID` assignment (the
`if [[ -z $GPU_ID ]]` guard then prints the skip). Do not restructure it into
the `nvidia.sh` shape if that changes other lines — the smallest fix is the
suffix.

**Verify** (PATH shim, no AMD hardware needed):

```bash
shim=$(mktemp -d); printf '#!/bin/sh\nexit 0\n' >"$shim/lspci"; chmod +x "$shim/lspci"
PATH="$shim:$PATH" bash bin/amd-rocm.sh --dry-run; echo "exit=$?"
```

Expected: `[*] No AMD GPU found. Skipping.` and `exit=0` (today: no output,
exit 1).

### Step 3: `gpu-setup.sh`: validate flags, handle unknown detectors

- Add the same argument loop (accept only `--dry-run`; unknown → usage, exit 1).
- Add a `default:` branch to the `case`:
  ```bash
  *)
      echo "[!] gpu-detect.sh returned '$GPU_TYPE', which this dispatcher does not know." >&2
      exit 1
      ;;
  ```
- Optional, and recommended for testability: read the detector through a seam,
  `GPU_TYPE="${OMACACHY_GPU_TYPE:-$(bash "$SCRIPT_DIR/gpu-detect.sh")}"`, and
  document it in the header as a test/diagnostic override (the repo's other
  seams use the `OMACACHY_` prefix). If plan 029 has landed, its `gpu` section
  can then exercise the `nvidia`/`amd` dispatch without hardware; mention it in
  your report either way.

**Verify**: `PATH="$shim:$PATH" bash bin/gpu-setup.sh --dry-run` → `No GPU
detected`, exit 0; `bash bin/gpu-setup.sh --bogus` → usage, exit 1;
`OMACACHY_GPU_TYPE=bogus bash bin/gpu-setup.sh` → the new error, exit 1 (only
if you added the seam).

### Step 4: Guard `gpu-detect.sh`'s pipeline

`bin/gpu-detect.sh` has no `set -e`, so today it is safe; confirm that when you
read it, and if the file gains strict mode later the `grep -q` calls are
already in `if` conditions. No change expected — record the confirmation in
your report instead of editing.

**Verify**: `sed -n '1,11p' bin/gpu-detect.sh` → unchanged.

### Step 5: Test cases

Add to `tests/run.sh` (in plan 029's `gpu` section if present):
1. no-AMD skip (Step 2's shim command) → exit 0 and the skip text;
2. `--bogus` on both vendor scripts → exit 1 and usage text;
3. `gpu-setup.sh --dry-run` under the empty shim → `No GPU detected`, exit 0;
4. (if the seam exists) `OMACACHY_GPU_TYPE=bogus gpu-setup.sh` → exit 1.

**Verify**: `tests/run.sh` → `0 failed`.

## Test plan

- The four cases above are the net; case 1 fails against the current
  `amd-rocm.sh` (exit 1, no output) — that is the regression.
- Real-hardware dry runs (`nvidia.sh --dry-run` on an NVIDIA box) remain
  unverifiable here; note it.

## Done criteria

- [ ] Unknown flags are refused by all three scripts with usage + exit 1
- [ ] `amd-rocm.sh` prints its skip on a non-AMD machine (shim command)
- [ ] `gpu-setup.sh` fails loudly on an unexpected detector value
- [ ] Lint gate exit 0; `tests/run.sh` `0 failed`
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- The wrapper passes arguments other than `--dry-run` to `gpu-setup.sh`
  (grep the call site: `grep -n 'gpu-setup.sh' bin/install-omarchy-quattro.sh`)
  — STOP if so; the strict parser would break the install.
- `gpu-detect.sh` can emit values beyond nvidia/amd/none (it cannot today) —
  handle them explicitly instead of widening the error branch.

## Maintenance notes

- If a new vendor script is added, the argument loop is the convention to copy.
- Reviewer: confirm the strict parsing cannot break the wrapper's own call
  (`run env OMACACHY_SKIP_USER_CONFIGS=… bash gpu-setup.sh` passes no
  arguments).
