# Plan 043: Install Omarchy's base package list, not just the closure

## Status

- **Priority**: P1
- **Effort**: S–M (downloads ~100 packages once)
- **Risk**: LOW
- **Depends on**: 037/039/042 (the closure entries)
- **Category**: bug
- **Planned at**: commit `213850f`, 2026-09-11
- **Executed**: 2026-09-11, in the same commit as this file.

## Why this matters

The wrapper installed `omarchy-settings omarchy omarchy-nvim` plus a small,
hand-maintained ISO closure — enough to run the apply stages, not enough to be
an Omarchy desktop. Upstream's ISO pacstraps
`/usr/share/omarchy/install/omarchy-base.packages` (147 names: `foot`, `grim`,
`fzf`, `evince`, `gnome-disk-utility`, `udiskie`, `imagemagick`, …), and the
`omarchy` package's dependencies do not pull them.

Measured on the first *fresh* lab provisioned from the pristine golden
(2026-09-11): **104 of the 147 were missing**, and the desktop reported it
itself — the panel showed `App failure: Error: Command not found: "udiskie"`
within a minute of the first login, and `foot` (Omarchy's terminal), `grim`
(screenshots), `fzf`, `bat`, `eza` and the rest of the stock toolset were
absent. Earlier gates never caught it because they ran on machines where an
earlier Omarchy install (or the ISO) had already provided those packages, and
because the closure was only ever checked against what the *apply* stages call.

## What changed

- `bin/install-omarchy-quattro.sh`: new step **"Omarchy base packages"** right
  after the package install and before the pre-apply gate. It reads
  `/usr/share/omarchy/install/omarchy-base.packages`, diffs it against
  `pacman -Qq`, and installs the missing entries with `--needed` (so a re-apply
  is a no-op, and packages the user removed deliberately stay removed only if
  they are not in Omarchy's list). Entries that no configured repo carries are
  reported and skipped instead of aborting the transaction. `pacman -S` here
  needs `OMARCHY_ALLOW_DIRECT_PACMAN=1`, like the first install step. Decision:
  `base_packages=installed:N | nothing-missing | nothing-installable |
  planned | list-missing`.
  - On a machine provisioned *before* this sweep existed, Omarchy's theme setup
    has already written some of these files unowned
    (`yaru-icon-theme` vs `/usr/share/icons/Yaru/scalable/actions/go-next
    -symbolic.svg` and `go-previous-symbolic.svg`, observed on the lab), so
    pacman aborts with "exists in filesystem". The step then retries once with
    `--overwrite` limited to exactly the paths pacman named — what a first
    install would have done — and fails loudly if the retry does not name any.
- `tests/fixtures/cachyos-limine-luks`: carries a `install/omarchy-base.packages`
  (three names) and expects `base_packages=planned`.

## Verification

- `tests/run.sh` → `258 passed, 0 failed`; lint gate exit 0.
- Guest (fresh CachyOS lab, Limine): the sweep installs the missing entries,
  the pre-apply gate then verifies the complete set, and after a reboot the
  panel shows no `App failure: udiskie` notification (`udiskie` is running).

## Considered and rejected

- **Extend `OMARCHY_ISO_CLOSURE` by hand again**: that is how 037/039/042
  happened — one gap found per real run, each fixed after the fact. A list
  maintained upstream is the version that does not rot.
- **Install the whole list before the omarchy package**: the file lives in that
  package, so it is not on disk yet.
- **Fail the install when entries are not in any repo**: upstream's list is the
  ISO builder's, and it can name packages that only exist there; a warning and
  a skip keeps the machine provisioned.
