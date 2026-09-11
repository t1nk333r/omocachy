# Plan 024: Close the package deny-policy holes (bootloaders, Mesa/AMD/Intel, lib32)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If any
> STOP condition occurs, stop and report — do not improvise. When done, update
> the status row for this plan in `plans/README.md` (or leave it to the
> reviewer).
>
> **Drift check (run first)**: `git diff --stat e80b564..HEAD -- bin/lib/profile.sh`
> On a mismatch with the excerpts below, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `e80b564`, 2026-09-11

## Why this matters

The importer installs the bundle's explicit package list as root with
`--noconfirm` (`bin/omacachy-profile-import.sh:356-359`, and through
paru/yay at `:374`). The deny policy exists to keep kernels, bootloaders and
the driver stack under CachyOS's install and `chwd` — but two of its regexes
have holes: the bootloader rule matches the long-removed name `refind-efi`
(so `refind` and `syslinux` pass), and the GPU rule only matches `nvidia*`
prefixes (so `mesa-git`, `lib32-mesa`, `vulkan-radeon`, `xf86-video-amdgpu`,
`opencl-mesa`, `lib32-opencl-nvidia`, `intel-media-driver` all pass). A
bundle whose list contains those reverses the target's `chwd`-selected driver
stack or drops bootloader files on a Limine machine.

## Current state

- `bin/lib/profile.sh:111-131`:
  ```bash
  PROFILE_PKG_DENY=(
      '^linux(-|$)|-headers$::kernel/headers — …'
      '^(limine|grub|refind-efi|systemd-boot)::bootloader — installed and configured by the CachyOS install'
      '^(nvidia|lib32-nvidia|opencl-nvidia|nvidia-utils|mesa-vdpau)::GPU driver stack — chwd owns it on CachyOS (bin/gpu-setup.sh)'
      '^(omarchy|omarchy-.*|quickshell|quickshell-git)$::installed by bin/install-omarchy-quattro.sh as packages'
      '^(base|base-devel|pacman|systemd|glibc|linux-firmware.*|mkinitcpio|sddm)$::base system — already provided by CachyOS'
      '^cachyos-::CachyOS metapackages — provided by the target install'
      '^tldr$::conflicts with CachyOS'"'"'s tealdeer (pick one by hand)'
  )

  profile_pkg_denied() {
      local pkg="$1" entry re reason
      for entry in "${PROFILE_PKG_DENY[@]}"; do
          re="${entry%%::*}"
          reason="${entry##*::}"
          if [[ $pkg =~ $re ]]; then
  ```
- Matching is `[[ $pkg =~ $re ]]` — an ERE, unanchored unless the entry says so.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Lint | `bash -n bin/*.sh bin/lib/*.sh tests/run.sh && shellcheck --severity=warning -x bin/*.sh bin/lib/*.sh tests/run.sh` | exit 0 |
| Policy probe | the loop in Step 3 | no `MISSED` lines, no `FALSE-DENY` lines |
| Fixture suite | `tests/run.sh` | `0 failed` |

## Scope

**In scope**: `bin/lib/profile.sh`, one regression case in `tests/run.sh`.
**Out of scope**: the importer's transaction code, `bin/gpu-setup.sh`, the
report text of skips.

## Git workflow

- Branch: `advisor/024-package-deny-policy`
- Commit message, e.g.: `Close the deny-policy holes for bootloaders and the GPU stack`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Rewrite the two rules

Replace the bootloader entry with:

```bash
'^(limine|limine-.*|grub|grub-.*|refind|syslinux|systemd-boot|systemd-boot-.*)$::bootloader — installed and configured by the CachyOS install'
```

Replace the GPU entry with:

```bash
'^(nvidia|lib32-nvidia|nvidia-.*|lib32-nvidia-.*|opencl-nvidia|lib32-opencl-nvidia|opencl-.*|lib32-opencl-.*|cuda|lib32-cuda|mesa|lib32-mesa|mesa-.*|lib32-mesa-.*|vulkan-.*|lib32-vulkan-.*|xf86-video-.*|intel-media-.*|libva-.*|lib32-libva-.*|rocm-.*|lib32-rocm-.*|hip-.*)$::GPU driver stack — chwd owns it on CachyOS (bin/gpu-setup.sh)'
```

Notes:
- Keep the reasons' text style; every skip is printed by the importer.
- `-.*` families are deliberate (e.g. `nvidia-580xx-utils`,
  `linux-cachyos-nvidia-open` is covered by the kernel rule already).
- Do not add `^vulkan-icd-loader` style exceptions; the deny list is a
  safety floor, and the operator can install anything by hand.

**Verify**: `bash -n bin/lib/profile.sh` → exit 0.

### Step 2: Keep the allow side intact

Confirm the new regexes do not catch ordinary packages. The probe list in
Step 3 includes allowed names; no change should be needed, but if a common
package (firefox, neovim, ripgrep, git, jq, zoxide, mise) matches, tighten the
offending alternation.

**Verify**: Step 3's `FALSE-DENY` count is 0.

### Step 3: Probe the policy directly

```bash
cd /home/t1nk33r/Projects/omacachy/omacachy
bash -c '
source bin/lib/profile.sh
deny="mesa-git lib32-mesa vulkan-radeon lib32-vulkan-radeon xf86-video-amdgpu opencl-mesa lib32-opencl-nvidia intel-media-driver refind syslinux limine-mkinitcpio-hook grub-btrfs nvidia-580xx-utils rocm-hip-runtime cuda"
allow="firefox neovim ripgrep git jq zoxide mise fd bat"
for p in $deny;  do profile_pkg_denied "$p" >/dev/null || echo "MISSED $p"; done
for p in $allow; do profile_pkg_denied "$p" >/dev/null && echo "FALSE-DENY $p"; done
echo probe-done'
```

Expected: `probe-done` with no `MISSED` or `FALSE-DENY` lines.

**Verify**: as above.

### Step 4: Regression case in `tests/run.sh`

Add a case that sources `bin/lib/profile.sh` and asserts the same two loops
(denied list all denied, allowed list all allowed). Model it on the harness's
existing `ok`/`bad` helpers; one `ok` per name is fine.

**Verify**: `tests/run.sh` → `0 failed`.

## Test plan

- Step 4's case is the regression net: it fails against the current policy
  (`mesa-git`, `refind` pass today) and passes after Step 1.
- The probe list is also the documentation of the policy's intent; extend it
  (not the regexes) when a new gap is found by hand.

## Done criteria

- [ ] The Step 3 probe prints no `MISSED`/`FALSE-DENY`
- [ ] `tests/run.sh` `0 failed`, including the new policy case
- [ ] The importer's skip messages still come from `profile_pkg_denied`'s
      reason text (no change to the caller)
- [ ] Lint gate exit 0
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- A probe name turns out to be a different package than assumed (e.g. a
  CachyOS-only name) — report instead of forcing the regex.
- The code no longer matches the excerpts (drift).

## Maintenance notes

- If CachyOS ever moves the driver stack out of `chwd`, the GPU rule's reason
  text (and the plan that owns the policy, `plans/018-*.md` §Package policy)
  must change together.
- Reviewer: the deny list is intentionally coarse; reject any suggestion to
  make it an allow-list in this plan — that is a design change.
