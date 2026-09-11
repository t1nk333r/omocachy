# Plan 035: Clean up the GPU scripts' duplicated boilerplate

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: tech-debt
- **Planned at**: commit `b3261f0`, 2026-09-11
- **Executed**: 2026-09-11, in the same commit as this file (reviewer pass).

## Why this matters

After the 019–034 batch the tree has no dead code, no unused variables and a
clean warning-level lint — but the three small GPU scripts carried the same
three-flag parser three times, and the two vendor scripts carried the same
session-env writer twice. That was the last copy-paste left, and it is the
kind that drifts: 033 had to fix the flag handling in all three files, and the
duplicated loop is why a misplaced `--dry-run` used to install for real.

## What changed

- `bin/lib/common.sh` gains two documented helpers:
  - `parse_dry_run_flag "$@"` — `--dry-run` anywhere sets `DRY_RUN=true`,
    `-h`/`--help` prints `Usage: $(basename "$0") [--dry-run]`, anything else
    is refused with usage on stderr. Adopted by `bin/nvidia.sh` and
    `bin/amd-rocm.sh` (15-line loops → one call each) and by
    `bin/gpu-setup.sh`, which now also sources the library — it never did.
  - `write_gpu_session_env LABEL CONTENT`, plus the `OMOCACHY_GPU_ENV_FILE`
    constant — the shared uwsm `env.d` write, including the
    `OMOCACHY_SKIP_USER_CONFIGS=1` print-only path. Adopted by both vendor
    scripts, which keep only their vendor content string.
- Net: −54 lines of duplicated boilerplate.

## Verification (done in the same commit)

- Byte-for-byte output equivalence of the pre/post scripts for:
  `nvidia.sh --dry-run` and `amd-rocm.sh --dry-run` (real AMD host, plus an
  `lspci` shim faking an NVIDIA card), each with and without
  `OMOCACHY_SKIP_USER_CONFIGS=1`; `gpu-setup.sh --dry-run` with and without
  the skip flag; `gpu-setup.sh --bogus` (refusal text). All seven diffs
  identical.
- `--help` / `--bogus` behaviour re-checked on all three scripts.
- Lint gate (`bash -n` + `shellcheck --severity=warning -x`) exit 0;
  `tests/run.sh` → `245 passed, 0 failed`.
- The equivalence check earned its keep immediately: the first attempt left
  `gpu-setup.sh` calling the helper without sourcing the library (`rc=127`);
  the diff caught it, the source line was added, and every diff came back
  identical.

## Considered and rejected

- **Splitting `bin/install-omarchy-quattro.sh` (1725 lines) into libraries**:
  rejected. Its flow *is* the specification, and its helpers and checks read
  ~20 globals that flow sets; extraction would add indirection and force
  file-level shellcheck disables without isolating anything.
- **`bin/debloat-quattro.sh`'s integer `DRY_RUN` (0/1) → boolean**: rejected
  for now — behaviour-free, but it touches a destructive script whose dry-run
  path the suite does not fully cover; the integer convention is
  self-contained and documented in the script's header.
- **The doctor's 8 × `A && B || C` (SC2015)**: left as-is — `pass`/`fail` are
  echo-based and always succeed, it is the file's house style, and the
  rewrites would add lines without changing behaviour.
- **`ls -1t` newest-backup lookup (SC2012)**: left; the globs are
  timestamp-suffixed by construction and a `find` replacement would be less
  readable.
- **`pkg_version` defined in both the wrapper (sysroot-aware) and the export
  script (one-liner)**: left; the duplication is a name, not logic — the
  wrapper's version exists for the sysroot seam and must not be shared.
- **The wrapper's log setup vs `start_logging`**: left; the wrapper needs a
  writability fallback and prints its own `Log:` banner, so the shared helper
  would grow a second mode for one caller.
- **SC2016 (16 ×) and SC2329 (6 ×)**: deliberate — single-quoted content that
  must not expand, and dynamic `stage_$name` dispatch — not findings.
