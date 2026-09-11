# Plan 044: Make the profile import survive a real CachyOS migration

## Status

- **Priority**: P1 (one item aborted the run outright)
- **Effort**: S–M
- **Risk**: LOW–MEDIUM (the packages stage's retry order changes)
- **Depends on**: 018 (the profile trio), 020/022 (bundle trust boundary, undo), 043 (the `--overwrite` pattern mirrored here)
- **Category**: bug (eight items from one real run)
- **Planned at**: the failure list below, produced by running the real migration in a
  CachyOS+Omarchy lab guest (bundle exported from `luna`, imported into the GRUB guest)
- **Executed**: 2026-09-11, same commit as this file.

## Why this matters

The migration story is the reason the project exists, and a real run found it did
not survive contact with a machine that had Omarchy installed but **no live
session** — the normal state right after
`bin/install-omarchy-quattro.sh` finishes.

Eight findings, from `packages-failed.txt` of that run
(`mangohud`, `mise-bin`, `pipewire-jack`, `yaru-icon-theme`, `chaotic-keyring`,
`chaotic-mirrorlist`; stage line `packages: PARTIAL (6 failed)`, exit status 0)
plus the transcript:

1. **BLOCKING.** `stage_configs` aborted the whole run after the merge.
   `newest_hypr="$(find …/hypr … | sort -rn | head -1 | cut -d' ' -f2)"` — with
   no `$XDG_RUNTIME_DIR/hypr`, `find` exits 1, `pipefail` propagates it and
   `set -e` kills the script. `packages`, `mise`, `services` and `verify` never
   ran. Reproduced on the guest: the log ended at the configs stage's rollback
   line and `grep -c '^--- packages ---'` was `0`, exit 1.
2. `pipewire-jack` (the source machine's JACK provider) against CachyOS's
   installed `jack2`: with `--noconfirm` pacman answers "no" to the removal
   prompt, the transaction fails to prepare.
3. `mise-bin` against an installed `mise` (both provide `mise`): the same
   conflict, and the single reason the 163-package batch was demoted into 163
   serial transactions (`failed to prepare transaction`).
4. `pacman -Qqen` cannot tell an official repo from a third-party *sync* repo,
   so the bundle's 226 "native" packages include 5 from `chaotic-aur`. The
   importer handed them to the AUR helper, which cannot provide
   `chaotic-keyring`/`chaotic-mirrorlist` at all.
5. `stage_packages` ran `pacman -S` with no `-Sy`, so a database that still
   names a rolled package 404s (`mangohud` through an old `python-matplotlib`
   entry) and the batch dies.
6. `yaru-icon-theme` hit `exists in filesystem`: a partial earlier setup wrote
   `/usr/share/icons/Yaru` unowned — the conflict plan 043 already fixed in the
   wrapper.
7. `packages: PARTIAL (6 failed)` matched neither the importer's own final
   `*FAILED*` check nor the doctor's, so six missing packages reported success.
8. The bundle's `.sha256` did not travel with the archive; the importer could
   only warn that it could not verify the bundle.

## What changed

`bin/omocachy-profile-import.sh`

- **The runtime probe is not fatal** (item 1). It is now guarded by
  `[[ -d $XDG_RUNTIME_DIR/hypr ]]` and `|| true`, and an empty result simply
  leaves `HYPRLAND_INSTANCE_SIGNATURE` unset — an absent instance means there is
  nothing to reload, not that the run should die.
- **Conflicts with the target win, out loud** (items 2, 3). One `pacman -Si` per
  candidate now also answers "does it conflict with something installed?", and
  the conflict is skipped like any other policy decision, naming the installed
  package (`pipewire-jack` → `jack2`, `mise-bin` → `mise`). A conflict whose
  name is installed outright is preferred in the message over the virtual name
  it provides; `pacman -Qi` resolves providers as the fallback. Nothing is
  removed: the reason says so and gives the operator the decision.
- **Retry ladder instead of a straight demotion** (items 5, 6). The batch
  transaction is tried once; on failure the databases are refreshed and the same
  transaction retried; if pacman named `exists in filesystem` paths, one more
  retry passes `--overwrite` with exactly those paths (the plan-043 pattern);
  only then does it fall back to one transaction per package.
- **A helper failure for a machine-specific repo is a skip, not an error**
  (item 4). A package whose bundle-recorded repo this machine does not configure
  (`chaotic-aur`) and that the AUR helper cannot provide becomes a printed policy
  skip naming the repo. It is deliberately *not* pre-skipped for its recorded
  repo: `helium-browser-bin`, `sway-audio-idle-inhibit-git` and `zen-browser-bin`
  are recorded as `chaotic-aur` on the source machine and obtainable here (AUR,
  or CachyOS's own repo), and dropping them would lose the apps the migration is
  for.
- **A partial package stage fails the run** (item 7): `packages: FAILED (n of m
  did not install)`, each failure named with its reason in the output and listed
  in `packages-failed.txt`. Policy skips never enter that list.

`bin/omocachy-profile-export.sh`

- **Records the source repo per package** (item 4): one `pacman -Si` per
  explicit package into `packages/repos.tsv` (`<pkg>\t<repo>`, `aur` for names no
  repo has), copied into the bundle, added to `manifest.json` as
  `packages.repo_of[]` and summarised as a `Package repos` row in `SUMMARY.md`.
- **Says the `.sha256` must travel beside the archive** (item 8), both when the
  archive is written and in the closing "Next:" block, because that is the file
  the importer verifies.

`tests/run.sh`

- New `packages` section: a stub `pacman`/`sudo`/`paru` answers the stage's
  queries, so the policy and the retries are driven for real without installing
  anything (conflict skips, the unconfigured-repo skip and its
  obtainable-package control, the refresh retry, the `--overwrite` retry, and
  the FAILED exit status).
- New `probe` section: an import with `HYPRLAND_INSTANCE_SIGNATURE` unset and no
  `$XDG_RUNTIME_DIR/hypr` must finish the configs stage (item 1's regression
  test).

`README.md` — §6: the `.sha256` must be copied with the archive, the two
target-aware package rules, the retry ladder, and that a partial package stage
fails the run.

## Verification

- Lint gate: `bash -n` clean and `shellcheck --severity=warning -x` clean on
  `bin/*.sh`, `bin/lib/*.sh` and `tests/run.sh`.
- `tests/run.sh`: **266 → 303 assertions, 0 failed** (31 new in `packages`,
  6 in `probe`). Mutation check — the pre-fix import against the new tests —
  fails 15 `packages` assertions and 3 `probe` assertions.
- Two export-side bugs were found and fixed by *running* the export, not by
  reading it: piping `pacman -Si` into `head` fails the pipeline under
  `pipefail` (SIGPIPE) and aborted the export mid-way (exit 1, no manifest);
  and `pacman -Si <virtual name>` prints several package blocks, so a `sed`
  extractor emitted extra malformed rows. The final exporter run produced 229
  rows for 229 packages with no malformed row, and `manifest.json` carried the
  same table (`packages.repo_of[]`).
- Guest (GRUB CachyOS lab, fresh wrapper install, **no live session**, egress),
  archive + `.sha256` transferred, `sha256sum -c` **OK**, bundle exported by the
  fixed exporter (`omocachy-profile-luna-20260911-224932`):
  - one uninterrupted `--bundle … --yes` run: `configs: OK`, `packages: OK`,
    `mise: OK`, `services: OK`, `verify: OK` — no abort, all five stages.
    The packages stage installed 59 packages from configured repos in one
    transaction, then 6 through `paru` (4 built/installed, the 2 chaotic-only
    names reclassified), then `mise install` brought up all 18 tools.
    `packages-failed.txt` **absent**; 11 policy skips, each printed with its
    reason (9 from the deny list, `pipewire-jack` for the `jack2` conflict, and
    the two `chaotic-aur` skips).
  - a second identical run (idempotency, and the exit status the first run's
    `nohup` could not report): **exit 0**, same five-stage result,
    `packages-failed.txt` absent again.
  - `bin/omocachy-doctor.sh --bundle <archive>`: **exit 0, 0 failed, 1 warning**
    ("3 explicit package(s) from the bundle are not installed here (8 more
    denied by policy)") — those 3 are exactly the packages the run printed a
    policy reason for. `hyprctl`/`omarchy-shell` IPC and the GPU-session check
    legitimately **SKIP** on a guest with no live session; they are not passes.
  - The refresh / `--overwrite` ladder was *not* needed on the guest: the
    wrapper had refreshed the databases minutes earlier and no file conflict
    occurred (the wrapper's own plan-043 sweep owns that path now). Both retries
    are pinned by the stub-pacman tests above.
  - Observed, not changed: the native batch hit two CachyOS-mirror 502s and one
    404 and recovered on its own ("too many errors from archlinux.cachyos.org,
    skipping for the remainder of this transaction"), and pacman's
    `--noconfirm` answered one provider prompt (`java-runtime=21`).

## Considered and rejected

- **Line 248 (`[[ -n $newest_hypr ]] && export …`) as a second footgun**: not
  reproduced. `bash -euo pipefail -c 'x=""; [[ -n $x ]] && export Y=$x; echo
  REACHED'` prints `REACHED` and exits 0 on the guest — a failing non-final
  command of an `&&` list does not trigger `set -e`. The pipeline above it was
  the whole abort. It is still written as an `if` for clarity.
- **Pre-skipping every package recorded from an unconfigured repo**: rejected.
  It reads like the literal fix for item 4, but on the real bundle it would skip
  5 packages of which 3 are obtainable here (`zen-browser-bin` from CachyOS's
  repo, `helium-browser-bin`/`sway-audio-idle-inhibit-git` from the AUR) — a
  silent loss of desktop apps. The repo table is used to explain a real helper
  failure instead, and the test pins both directions.
- **Denying `*-dkms` or driver packages by policy**: not in the failure list, and
  `mediatek-mt7927-dkms` is a legitimate source-machine package (it builds here;
  the guest has `linux-cachyos-headers`). Left alone.
- **Removing `jack2` to honour the source's provider**: rejected. The importer's
  contract is merge-not-delete, and pacman cannot take the removal decision
  under `--noconfirm`; the printed reason and the one-command hint are the
  honest version.
- **Editing `bin/omocachy-doctor.sh`**: out of scope for this change. Its own
  hypr-probe has no `-e`, which is why it survived the same pipeline.
